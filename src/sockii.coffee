# ex: set tabstop=4 shiftwidth=4 expandtab:

# Better stack traces
require 'longjohn'

EventEmitter = require('events').EventEmitter
socketio = require 'socket.io'
url = require 'url'
_ = require 'lodash'
httpProxy = require 'http-proxy'
http = require 'http'
WebSocket = require 'ws'
httpRequest = require 'request'
winston = require 'winston'
fspath = require 'path'
url = require 'url'
uuid = require 'node-uuid'
exceptions = require './exceptions'

OPEN_WS_STATES = [WebSocket.CONNECTING, WebSocket.OPEN]

class Sockii extends EventEmitter
    plugins: {}
    httpMappers: []
    wsMappers: []
    httpHandlers: []
    socketeers: []
    sockets: {}

    constructor: (@config, @configPath) ->
        @app = require('http').createServer()

        @config.logger ?= {}
        @config.logger.prefix ?= '[sockii]'

        @config.logger.transports ?= [
            transport: 'Console'
            colorize: yes
            timestamp: yes
        ]

        transports = []
        for transportOptions in @config.logger.transports
            if '/' in transportOptions.transport
                cls = require transportOptions.transport
            else
                cls = winston.transports[transportOptions.transport]
            delete transportOptions.transport

            transports.push new cls transportOptions

        @_logger = new winston.Logger
            transports: transports

        # We wrap the logger here so we can add a custom prefix
        @logger =
            debug: (msg, data) => @_logger.debug "#{ @config.logger.prefix } #{ msg }", data
            info: (msg, data) => @_logger.info "#{ @config.logger.prefix } #{ msg }", data
            warning: (msg, data) => @_logger.warning "#{ @config.logger.prefix } #{ msg }", data
            warn: (msg, data) => @_logger.warn "#{ @config.logger.prefix } #{ msg }", data
            error: (msg, data) => @_logger.error "#{ @config.logger.prefix } #{ msg }", data

        # Default for binding
        @config.listen ?= {}
        @config.listen.host ?= '127.0.0.1'
        @config.listen.port ?= 80

        # Used for loading plugins
        @config.pluginSearchPath ?= []
        @config.pluginSearchPath.push "#{ __dirname }/plugins/"

        # Allow ACL against a base domain so we can let subdomains in
        if @config.aclAllowBaseDomain?
            domain = @config.aclAllowBaseDomain.replace '.', '[.]'
            @baseDomainRegex = new RegExp "(^|[.])#{ domain }([:][0-9]+)?$"

        # Whether to check the X-Requested-With header to prevent non-AJAX requests,
        # and thus prevent CSRF attacks
        @config.checkXRequestedWith ?= true

        # Base path to strip from ignored paths
        @config.basePath ?= ''

        @proxy = new httpProxy.RoutingProxy @config.httpProxy

        @logger.debug 'Config:', @config
    
    loadPlugins: (plugins) ->
        if plugins
            for name in plugins
                if name.indexOf('/') isnt -1
                    paths = ['']
                else
                    paths = @config.pluginSearchPath

                paths.push @configPath

                @logger.info "Loading plugin #{ name }"
                cls = null
                for path in paths
                    if path and path[path.length-1] isnt '/'
                        path += '/'
                    try
                        cls = require fspath.normalize("#{ path }#{ name }")
                        break
                    catch e
                        if e.code isnt 'MODULE_NOT_FOUND' or e.toString().indexOf(name) is -1
                            @logger.error e

                if cls isnt null
                    @plugins[name] = new cls @, @config[name] or {}
                else
                    @logger.error "Unable to load plugin #{ name } with plugin search paths", paths

    loadPlugin: (plugin) ->
        @loadPlugins [plugin]

    listen: ->
        @logger.info "Listening on #{ @config.listen.host }:#{ @config.listen.port }"
        @server = @app.listen @config.listen.port, @config.listen.host

        sioOptions =
            origins: '*:*'
            logger: @logger

        if @config['socket.io']?
            sioOptions = _.extend sioOptions, @config['socket.io']

        @logger.info "Setting socket.io options:", sioOptions
        @io = socketio.listen @server, sioOptions

        # Send TCP packets without Nagle buffering
        @io.server._handle?.setNoDelay? yes

        @loadPlugins @config.plugins
        @bindEvents()

    bindEvents: ->
        process.on 'SIGHUP', @sighupHandler
        process.on 'uncaughtException', @errorHandler

        @server.on 'request', @httpRequestHandler
        @io.on 'connection', @websocketHandler

        @proxy.on 'proxyError', @handleProxyError

        # Plugins
        httpFuncs = ["request", "get", "post", "put", "delete"]
        for name, plugin of @plugins
            if _.isFunction plugin.map
                # HTTP address mapping plugin
                @httpMappers.push plugin

            if _.isFunction plugin.wsMap
                # WebSocket address mapping plugin
                @wsMappers.push plugin

            if _.intersection(httpFuncs, _.functions(plugin)).length > 0
                # HTTP plugin
                @httpHandlers.push @wrapHttpHandler(plugin)

            if _.isFunction plugin.socket
                # WebSocket plugin
                @socketeers.push plugin

    wrapHttpHandler: (plugin) ->
        {
            handle: (request, response, next) ->
                method = request.method?.toLowerCase()
                plugin.request?(request, response, next)
                plugin[method]?(request, response, next)
        }

    sighupHandler: =>
        # Ensure log file pointers are reset on SIGHUP
        @_logger.transports?.file?._createStream()

    errorHandler: (error, request, response) =>
        # Generic error handler

        # Don't log socket hang up errors unless explicitely enabled
        if error.code isnt 'ECONNRESET' or @config.logResets
            @logger.error error, error.stack

    handleRequestError: (error, request, response) =>

        if error instanceof exceptions.HttpError
            response.writeHead error.statusCode, 'Content-Type': 'text/plain'

            if request.method isnt 'HEAD'
                response.write error.responseBody

            response.end()
        else
            throw error

    handleProxyError: (error, request, response) =>
        response.writeHead 500, 'Content-Type': 'text/plain'

        if request.method isnt 'HEAD'
            response.write 'Internal Server Error'

        response.end()
        @errorHandler(error)

    httpRequestHandler: (request, response) =>
        # Send TCP packets without Nagle buffering
        request.connection?.setNoDelay? yes
        response.connection?.setNoDelay? yes

        if url.parse(request.url).pathname is '/'
            response.writeHead 404,
                'Content-Length': 0
                'Content-Type': 'text/html'
            return response.end ''

        if @config.checkXRequestedWith \
                and request.headers['x-requested-with']?.toLowerCase() isnt 'xmlhttprequest'
            # Prevent CSRF attacks by only allowing AJAX requests
            response.writeHead 405,
                'Content-Length': 0
                'Content-Type': 'text/html'
            return response.end ''

        allowOrigin = no
        if (@config.aclAllowAll or
                (@config.aclAllowBaseDomain? and @baseDomainRegex.test(request.headers.origin)) or
                (@config.aclAllowDomains? and request.headers.origin in @config.aclAllowDomains))
            allowOrigin = yes

        # Add Access-Control-Allow-Origin headers for all requests
        if allowOrigin and response.writable and not response.finished
            # Allow this domain
            response.setHeader 'Access-Control-Allow-Origin', request.headers.origin
            response.setHeader 'Access-Control-Allow-Credentials', 'true'
            # Whitelist all the HTTP methods we use
            response.setHeader 'Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, HEAD, OPTIONS'
            # Whitelist pagination headers
            response.setHeader 'Access-Control-Expose-Headers', 'X-Total-Number, X-First-Page, X-Previous-Page, X-Next-Page, X-Last-Page, X-Barium'

            if request.method is 'OPTIONS'
                # For pre-flight requests, if they're asking about valid headers,
                # just echo the list back for all valid hosts
                if request.headers['access-control-request-headers']?
                    response.setHeader 'Access-Control-Allow-Headers', request.headers['access-control-request-headers']

                response.writeHead 200,
                    'Content-Length': 0
                    'Content-Type': 'text/html'
                response.end ''
                return

        # Ignore favicon and socket.io requests
        checkUri = request.url
        if request.url.slice(0, (11 + @config.basePath.length)) in ["#{@config.basePath}/favicon.ic", "#{@config.basePath}/socket.io/"]
            console.log request.url
            return

        # Ignore HEAD requests
        if request.method is 'HEAD' then return

        # Buffer the request so we don't lose events or data during async ops
        buffer = httpProxy.buffer request

        # Address mappers
        request.url = @httpAddressMap request.url

        # Add host so we can set it in the service for Link addresses in pagination
        request.headers['honshuu-host'] = request.headers['host']
        request.headers['honshuu-orig-url'] = request.url
        request.headers['X-Barium'] = uuid.v4()

        # Callback for handling what to do next after plugin handlers have run
        called = 0
        next = (error, done) =>
            if error
                return @handleRequestError error, request, response

            if done
                called++

            if @httpHandlers.length is 0 or called is @httpHandlers.length
                timeout = setTimeout =>
                    if response.writable and not response.finished
                        @logger.error 'Timeout called, go to the naughty step', response
                        response.statusCode = 500
                        response.write '{"error":"upstream_timeout"}'
                        response.end()
                , @config.timeout

                clear = -> clearTimeout timeout
                response.on 'close', clear

                @logger.info "Proxying #{ request.url }"
                @proxy.proxyRequest request, response, buffer: buffer

        # Plugin request handlers
        if @httpHandlers.length > 0
            for handler in @httpHandlers
                process.nextTick -> handler.handle request, response, next
        else
            next null, yes

    httpAddressMap: (address, request, response, socket) ->
        if @httpMappers.length > 0
            address = _.reduce @wsMappers, (address, mapper) ->
                mapper.map address, request, response, socket
            , address
        else
            address

    wsAddressMap: (address, socket) ->
        if @wsMappers.length > 0
            address = _.reduce @wsMappers, (address, mapper) ->
                mapper.map address, socket
            , address
        else
            address

    dispatchHttpRequest: (socket, data) ->
        address = "#{ data['$sockiiEndpoint'] }#{ data.url }"
        address = @httpAddressMap address, off, off, socket

        # Use node-http-proxy's routing table
        location = @proxy.proxyTable.getProxyLocation
            headers:
                host: @config.routerBaseHost
            url: "/#{ data['$sockiiEndpoint'] }#{ data.url }"

        if not location then return

        # Build a HTTP request
        method = data.method.toLowerCase()
        options =
            url: "http://#{ location.host }:#{ location.port }#{ address }"
            method: method
            jar: off
            pool: off

        # If the frontend says we're sending JSON, address the param
        # to querystring and add the JSON to the body
        if data.jsonPayload
            options.qs =
                jsonPayload: 1
            options.json = data.params

        else if method in ['post', 'put']
            # POST and PUT params go in the body, but querystring encoded
            # options.form also adds extra HTML form encoding content-type,
            # but we'll just ignore this in the backend anyway.
            options.form = data.params

        else
            # GET and DELETE params can just go on the querystring
            options.qs = data.params

        # Do the request, and on result push the data back through the socket as a message
        httpRequest options, (error, response, body) ->
            if error
                socket.emit 'message',
                    $sockiiEndpoint: data['$sockiiEndpoint']
                    url: data.url
                    method: data.method
                    error: error
            else
                socket.emit 'message',
                    $sockiiEndpoint: data['$sockiiEndpoint']
                    url: data.url
                    method: data.method
                    response: JSON.parse body

    websocketHandler: (socket) =>

        socket.on 'disconnect', =>
            @logger.debug "Socket '#{ socket.id }' disconnected"
            # Clean up any upstream websocket connections
            if _.size(@sockets[socket.id]) > 0
                @logger.debug "Deleting upstream sockets for #{socket.id}"
                # Close sockets asynchronously, e.g. add them to the node ioloop
                for endpoint, sock of @sockets[socket.id]
                    process.nextTick -> sock.close(1001)

            delete @sockets[socket.id]

        socket.on 'message', (data) =>
            if not data['$sockiiEndpoint']? then return

            if data.http then return @dispatchHttpRequest socket, data

            called = 0
            next = (error, done) =>
                if error
                    throw error

                if done
                    called++

                if @socketeers.length is 0 or called is @socketeers.length
                    # Extra data to append to messages from plugins
                    if socket.handshake._appendToMsg?
                        data = _.extend data, socket.handshake._appendToMsg

                    # Endpoint is a key to map to a backend WebSocket speaking service
                    endpoint = data['$sockiiEndpoint']

                    if not @config.wsMaps[endpoint]? then return

                    address = @config.wsMaps[endpoint]
                    if socket.handshake._appendToSocket?
                        parsed = url.parse address
                        parsed.query = socket.handshake._appendToSocket
                        address = url.format parsed

                    # Address maps
                    address = @wsAddressMap address

                    @logger.info "Mapping to: #{ address }"

                    id = socket.id

                    @sockets[id] ?= {}

                    # If the socket is closing or closed or any other state that may be added later,
                    # other than connecting or open, open a new client.
                    if not @sockets[id][endpoint]? or @sockets[id][endpoint].readyState not in OPEN_WS_STATES

                        setupWs = =>
                            if not @sockets[id]?
                                # Downstream connection must have closed, so skip connect
                                return

                            @logger.debug "Setting up ws for #{ id }:#{ endpoint } to #{ address }"
                            @sockets[id][endpoint] = new WebSocket "#{ address }"

                            # Ping the websocket every 30 seconds
                            heartbeatIntId = setInterval =>
                                @sockets[id]?[endpoint]?.ping(null, {}, true)
                            , 30000

                            @sockets[id][endpoint].on 'open', =>
                                @logger.debug "Opened ws for #{ id }:#{ endpoint }"

                            @sockets[id][endpoint].on 'message', (data, flags) =>
                                @logger.debug "Received data from endpoint '#{ endpoint }' for socket '#{ id }': #{ data }"
                                data = JSON.parse data
                                data['$sockiiEndpoint'] = endpoint
                                socket.emit 'message', data

                            # Whenever the client socket closes, remove it from the pool
                            @sockets[id][endpoint].on 'close', (code) =>
                                clearInterval heartbeatIntId

                                # Only reconnect if we're not being explicitly closed from a downstream disconnect
                                # or we've accidentally been fired afterwards
                                if code isnt 1001 and @sockets[id]?
                                    # Inform the upstream client that the downstream socket has closed
                                    @logger.debug "Firing epclose event for socket #{ id }"
                                    socket.emit 'epclose',
                                        endpoint: endpoint

                                    setTimeout setupWs, 2000

                        setupWs()

                    if @sockets[id][endpoint].readyState isnt WebSocket.OPEN
                        # If the socket isn't open yet, add a callback
                        @sockets[id][endpoint].on 'open', =>
                            @sockets[id][endpoint].send JSON.stringify(data), { mask: on }
                    else
                        # Socket is already open so we can just send data
                        @sockets[id][endpoint].send JSON.stringify(data), { mask: on }

            if @socketeers.length > 0
                for handler in @socketeers
                    process.nextTick -> handler.socket socket, next
            else
                next null, yes

module.exports = Sockii
