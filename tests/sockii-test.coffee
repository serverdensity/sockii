# ex: set tabstop=4 shiftwidth=4 expandtab:
vows = require 'vows'
assert = require 'assert'
nock = require 'nock'
fs = require 'fs'
qs = require 'querystring'
httpRequest = require 'request'
Sockii = require '../src/sockii'
ioclient = require 'socket.io-client'
WebSocketServer = require('ws').Server
_ = require 'lodash'
mongodb = require 'mongodb'

config = JSON.parse fs.readFileSync('./config/testing.json')

cookies = httpRequest.jar()
cookies.setCookie(httpRequest.cookie('session=testsession'), 'http://127.0.0.1:8079', ->)

badCookies = httpRequest.jar()
badCookies.add httpRequest.cookie('session=badtestsession')

headers =
    'X-Requested-With': 'XMLHTTPRequest'

sockii = new Sockii config
sockii.listen()

vows.describe('HTTP Requests').addBatch(

    "Sockii":
        topic: ->
            mongo = new mongodb.Db('sessions', new mongodb.Server('127.0.0.1', mongodb.Connection.DEFAULT_PORT, {auto_reconnect: yes}), {safe: yes})
            mongo.open (error, db) =>
                db.collection 'sessions', (error, collection) =>
                    doc =
                        sessId: 'testsession'
                        d:
                            accountId: 'testaccount'
                            _id: 'testuser'

                    collection.update {sessId: 'testsession'}, doc, {upsert: true, safe: true}, (error, result) =>
                        doc =
                            sessId: 'badtestsession'
                            d:
                                accountId: 'internal'
                                _id: 'badtestuser'

                        collection.update {sessId: 'badtestsession'}, doc, {upsert: true, safe: true}, @callback
            return

        "HTTP":
            "inventory -":
                topic: ->
                    inventory = nock('http://inventory.sockii.dev')
                        .get('/?accountId=testaccount&userId=testuser')
                        .reply(200, 'OK')

                    httpRequest.get
                        url: 'http://127.0.0.1:8079/svc/inventory/'
                        jar: cookies
                        headers: headers
                    , @callback

                    return

                "GET /inventory/ Will proxy to / on port :80":
                    (error, response, body) ->
                        assert.isNull error
                        assert.equal body, 'OK'

            "users -":
                topic: ->
                    data = JSON.stringify
                        _id: '1234567890'
                        firstName: 'foo'
                        lastName: 'bar'

                    users = nock('http://users.sockii.dev')
                        .get('/accounts/blah?accountId=testaccount&userId=testuser')
                        .reply(500)
                        .get('/accounts/1234567890/?accountId=testaccount&userId=testuser')
                        .reply(200, data)

                    httpRequest.get
                        url: 'http://127.0.0.1:8079/svc/users/accounts/blah'
                        jar: cookies
                        headers: headers
                    , @callback
                    return

                "GET /users/accounts/blah will proxy to /accounts/blah and error with 500 status code":
                    (error, response, body) ->
                        assert.equal response.statusCode, 500

                "":
                    topic: ->
                        httpRequest.get
                            url: 'http://127.0.0.1:8079/svc/users/accounts/1234567890/'
                            jar: cookies
                            headers: headers
                        , @callback
                        return

                    "GET /users/accounts/1234567890/ will proxy to /accounts/1234567890/ and return a string with JSON in it":
                        (error, response, body) ->
                            data = JSON.stringify
                                _id: '1234567890'
                                firstName: 'foo'
                                lastName: 'bar'

                            assert.isNull error
                            assert.equal body, data

            "unknown -":
                topic: ->
                    httpRequest.get
                        url: 'http://127.0.0.1:8079/svc/rhp9th4398t4q9gt94/r043hprt0843j98t'
                        jar: cookies
                        headers: headers
                    , @callback

                    return

                "GET /rhp9th4398t4q9gt94/r043hprt0843j98t will fail to proxy /rhp9th4398t4q9gt94/r043hprt0843j98t":
                    (error, response, body) ->
                        assert.isNull error

                        if response?.statusCode
                            assert.equal response.statusCode, 404

                "invalid session":
                    topic: ->
                        httpRequest.get
                            url: 'http://127.0.0.1:8079/svc/inventory/devices/blah'
                            headers: headers
                        , @callback
                        return

                    "Requests without a valid session will fail":
                        (error, response, body) ->
                            assert.equal response.statusCode, 403
                            assert.equal body, 'Not Authorised'

                "internal accountId":
                    topic: ->
                        httpRequest.get
                            url: 'http://127.0.0.1:8079/svc/inventory/devices/blah'
                            jar: badCookies
                            headers: headers
                        , @callback
                        return

                    "Requests with session.d.accountId=internal will fail":
                        (error, response, body) ->
                            assert.equal response.statusCode, 403
                            assert.equal body, 'Not Authorised'

                "csrf check":
                    topic: ->
                        httpRequest.get
                            url: 'http://127.0.0.1:8079/svc/inventory/blah'
                        , @callback

                        return

                    "Requests without correct X-Requested-With will fail":
                        (error, response, body) ->
                            assert.equal response.statusCode, 405

            "cloud -":
                topic: ->
                    data =
                        apiCredentials: 'test'
                        accountId: '1234567890'

                    monkeys = nock('http://monkeys.sockii.dev:8888')
                        .post('/nodes/?accountId=testaccount&userId=testuser', qs.stringify(data).toString('utf8'))
                        .reply(200, 'OK')

                    httpRequest.post
                        url: 'http://127.0.0.1:8079/svc/monkeys/nodes/'
                        jar: cookies
                        form: data
                        headers: headers
                    , @callback

                    return

                "POST /monkeys/nodes/ will proxy to /nodes/ on port :8888":
                    (error, response, body) ->
                        assert.equal body, 'OK'

        "WebSocket":
            topic: ->
                server = new WebSocketServer
                    port: 8095

                server.on 'connection', (socket) ->
                    socket.on 'message', (data) ->
                        socket.send JSON.stringify({'msg': 'OK'})

                sockii._ws_test_server = server
                server

            "endpoint -":
                topic: (server) ->
                    client = ioclient.connect 'http://127.0.0.1:8079',
                        transports: ['websocket']

                    callback = (data) =>
                        if data._test
                            @callback data
                    client.on 'connect', =>
                        client.emit 'message',
                            $sockiiEndpoint: 'wstest'
                            foo: 'bar'
                            _test: yes

                        client.on 'message', (data) =>
                            callback data

                "$sockiiEndpoint proxies message to monkeys websocket and returns data back to client":
                    (data) ->
                        if data._test
                            assert.equal data.foo, "bar"

).addBatch(
    "When tests are done":
        topic: ->
            sockii._ws_test_server.close()
            sockii.close()
).exportTo module

