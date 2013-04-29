# ex: set tabstop=4 shiftwidth=4 expandtab:
url = require 'url'
mongo = require 'mongodb'
async = require 'async'
HttpError = require('../exceptions').HttpError

class MongoSessionsPlugin

    queries: []

    constructor: (@sockii, @config) ->
        cookieName = @config.cookieName or 'session'
        @re = new RegExp "[; ]?#{ cookieName }=([^;]+)"

        host = @config.mongo?['host'] or 'localhost'
        port = @config.mongo?['port'] or mongo.Connection.DEFAULT_PORT
        collection = @config.mongo?['collection'] or 'sessions'
        @sessionRequired = @config.required or no
        @updateField = @config.updatedDatetimeField or 'tU'
        # Update sessions for socket users every 20 minutes by default
        @sessionUpdateInterval = @config.updateInterval or 1200000

        mongo = new mongo.Db(collection, new mongo.Server(host, port, {auto_reconnect: yes}), {native_parser: on, safe: yes})
        mongo.open (error, db) =>
            if error
                @sockii.logger.error error
                process.exit 1
            else
                @db = db
                if @queries.length > 0
                    async.parallel (async.apply(cb, db) for cb in @queries)

        @sockii.io.set 'authorization', @socketAuth
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
        request.url = url.format parsed
        @sockii.logger.debug "Original url: #{ request.url }"

        error = null
        cookiePresent = no

        if request?.headers?.cookie?
            sessionId = request.headers.cookie.match @re
            if sessionId
                cookiePresent = yes
                sessionId = sessionId[1]
                @runDbQuery (db) =>
                    db.collection 'sessions', (error, collection) =>
                        @sockii.logger.info "Looking up session #{ sessionId }"
                        update = { '$set': {}}
                        update['$set'][@updateField] = new Date
                        collection.findAndModify { sessId: sessionId }, [['_id','asc']], update, {}, (error, doc) =>
                            @sockii.logger.debug "Data for #{ sessionId }:", doc
                            error = null

                            if doc?.d?.accountId? and doc.d.accountId isnt 'internal'
                                parsed.query.accountId = doc.d.accountId
                                parsed.query.userId = doc.d._id
                                request.url = url.format parsed
                                @sockii.logger.debug "Rewritten url: #{ request.url }"
                            else if @sessionRequired
                                error = new HttpError 403, 'Not Authorised'

                            next error, yes

        if not cookiePresent and @sessionRequired
            error = new HttpError 403, 'Not Authorised'

        next error, not @sessionRequired

    socketAuth: (handshakeData, next) =>
        handshakeData._appendToSocket ?= {}
        handshakeData._appendToMsg ?= {}

        if handshakeData?.headers?.cookie?
            sessionId = handshakeData.headers.cookie.match @re
            if sessionId
                sessionId = sessionId[1]
                @runDbQuery (db) =>
                    db.collection 'sessions', (error, collection) =>
                        @sockii.logger.info "Looking up session #{ sessionId }"
                        update = { '$set': {}}
                        update['$set'][@updateField] = new Date
                        collection.findAndModify { sessId: sessionId }, [['_id','asc']], update, {}, (error, doc) =>
                            @sockii.logger.debug "[ws] Data for #{ sessionId }:", doc
                            passed = yes

                            if doc?.d?.accountId? and doc.d.accountId isnt 'internal'
                                handshakeData._appendToSocket.accountId = doc.d.accountId
                                handshakeData._appendToSocket.userId = doc.d._id
                            else if @sessionRequired
                                passed = no

                            next null, passed
            else
                next null, not @sessionRequired

    socketSessionUpdate: (socket) =>
        intervalId = null
        sessionId = socket.handshake.headers.cookie.match @re
        sessionId = sessionId?[1]
        setInterval =>
            @runDbQuery (db) =>
                db.collection 'sessions', (error, collection) =>
                    update = { '$set': {}}
                    update['$set'][@updateField] = new Date
                    collection.update { sessId: sessionId }, update, { safe: no }
        , @sessionUpdateInterval

        socket.on 'close', -> clearInterval intervalId


module.exports = MongoSessionsPlugin
