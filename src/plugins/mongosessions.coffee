# ex: set tabstop=4 shiftwidth=4 expandtab:
_ = require 'lodash'
fs = require 'fs'
url = require 'url'
mongo = require 'mongodb'
async = require 'async'
HttpError = require('../exceptions').HttpError

class MongoSessionsPlugin

    queries: []

    constructor: (@sockii, @config) ->
        cookieName          = @config['cookieName'] or 'session'
        @re                 = new RegExp "[; ]?#{ cookieName }=([^;]+)"

        host                = @config.mongo?['host'] or 'localhost'
        port                = @config.mongo?['port'] or mongo.Connection.DEFAULT_PORT
        db                  = 'sessions'
        collection          = @config.mongo?['collection'] or 'sessions'
        @sessionRequired    = @config.required or no
        @updateField        = @config['updatedDatetimeField'] or 'tU'

        # Update sessions for socket users every 20 minutes by default
        @sessionUpdateInterval = @config['updateInterval'] or 1200000

        options =
            auto_reconnect: yes

        if @config.mongo?.options?
            options = _.extend options, @config.mongo.options

        rsName = options.rs_name or options.replicaSet or null

        if rsName
            servers = []

            for host in host.split(',')
                servers.push(new mongo.Server(host, port, options))

            rsOptions =
                rs_name: rsName
                read_secondary: yes

            servers = new mongo.ReplSet(servers, rsOptions)
        else
            servers = new mongo.Server(host, port, options)

        mongo = new mongo.Db(db, servers, {safe: yes})

        mongo.open (error, db) =>
            if error
                @sockii.logger.error error
                process.exit 1
            else
                @db = db

                if @queries.length > 0
                    async.parallel (async.apply(cb, db) for cb in @queries)

        @sockii.io.use @socketAuth
        @sockii.io.on 'connection', @socketSessionUpdate

    runDbQuery: (callback) ->
        if not @db?
            @queries.push callback
        else
            callback @db

    request: (request, response, next) =>

        parsed = url.parse request.url, on

        # We delete this so query object property is used for querystring
        delete parsed.search

        # Remove any IDs sent externally, in case of HAXXXXXxxxx
        delete parsed.query.accountId
        delete parsed.query.userId
        delete parsed.query.internal

        request.url = url.format parsed

        @sockii.logger.debug "Original url: #{ request.url }"

        if @sockii.config.checkXRequestedWith and request.headers['x-requested-with']?.toLowerCase() isnt 'xmlhttprequest'

            # Prevent CSRF attacks by only allowing AJAX requests
            error = new HttpError 405, ''

            next(error, yes)

            return

        error           = null
        cookiePresent   = no

        if request?.headers?.cookie?
            sessionId = request.headers.cookie.match @re

            if sessionId
                cookiePresent   = yes
                sessionId       = sessionId[1]

                @runDbQuery (db) =>
                    db.collection 'sessions', (error, collection) =>
                        @sockii.logger.info "Looking up session #{ sessionId }"

                        update =
                            '$set': {}

                        update['$set'][@updateField] = new Date

                        collection.findAndModify { sessId: sessionId }, [['_id','asc']], update, {}, (error, doc) =>
                            @sockii.logger.debug "Data for #{ sessionId }:", doc: doc
                            error = null

                            if doc?.d?.accountId? and doc.d.accountId isnt 'internal'
                                parsed.query.accountId = doc.d.accountId
                                parsed.query.userId = doc.d._id
                                request.url = url.format parsed

                                @sockii.logger.debug "Rewritten url: #{ request.url }"
                            else if @sessionRequired
                                error = new HttpError 403, 'Not Authorised'

                            next(error, yes)

        if not cookiePresent and @sessionRequired
            error = new HttpError 403, 'Not Authorised'

        next(error, not @sessionRequired)

    socketAuth: (socket, next) =>
        handshakeData = socket.request

        if handshakeData?.headers?.cookie?
            sessionId = handshakeData.headers.cookie.match @re

            if sessionId
                sessionId = sessionId[1]

                @runDbQuery (db) =>
                    db.collection 'sessions', (error, collection) =>
                        @sockii.logger.info "[ws] Looking up session #{ sessionId }"

                        update =
                            '$set': {}

                        update['$set'][@updateField] = new Date()

                        collection.findAndModify { sessId: sessionId }, [['_id','asc']], update, {}, (error, doc) =>
                            @sockii.logger.debug "[ws] Data for #{ sessionId }:", doc: doc
                            passed = yes

                            if doc?.d?.accountId? and doc.d.accountId isnt 'internal'
                                socket.handshake._appendToSocket =
                                    accountId: doc.d.accountId
                                    userId: doc.d._id

                            else if @sessionRequired
                                passed = no

                            if passed
                                next()
                            else
                                next(new Error("not authorized"))
            else
                if @sessionRequired
                    next(new Error("not authorized"))
                else
                    next()

    socketSessionUpdate: (socket) =>
        intervalId  = null
        sessionId   = socket.handshake.headers.cookie.match @re
        sessionId   = sessionId?[1]

        setInterval =>
            @runDbQuery (db) =>
                db.collection 'sessions', (error, collection) =>
                    update = { '$set': {}}
                    update['$set'][@updateField] = new Date
                    collection.update { sessId: sessionId }, update, { safe: no }
        , @sessionUpdateInterval

        socket.on 'close', -> clearInterval intervalId


module.exports = MongoSessionsPlugin
