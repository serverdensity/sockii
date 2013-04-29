# ex: set tabstop=4 shiftwidth=4 expandtab:

class HttpError
    statusCode: 500
    responseBody: ''

    constructor: (@statusCode, @responseBody) ->

module.exports =
    'HttpError': HttpError
