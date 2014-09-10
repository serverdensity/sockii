var fs = require('fs');
var path = require('path');
var optimist = require('optimist');
var _ = require('lodash');

argv = optimist.usage('WebSocket and HTTP aggregator/proxy\nUsage: $0\n\nAny argument passed that aren\'t defined below will override options from the config file.')
        .alias('c', 'config')
        .default('c', './config/development.json')
        .describe('c', 'Config file path')
        .alias('h', 'help')
        .boolean('h')
        .default('h', false)
        .describe('h', 'This help')
        .alias('p', 'pidfile')
        .default('p', './.sockii.pid')
        .describe('p', 'PID file path')
        .argv;

if (argv.h) {
    optimist.showHelp(console.log);
    process.exit(0);
}

// Always ignore -n, this is used by the bin/sockii wrapper to inject arguments to node.js
if (argv.n) {
    delete argv.n;
}

var configPath = argv.c;
configPath = path.resolve(configPath);

var config = JSON.parse(fs.readFileSync(configPath));

// Remove config file values from argv so we don't merge them with config
if (argv.c) {
    delete argv.c;
}
if (argv.config) {
    delete argv.config;
}

config.configPath = configPath;
module.exports = _.extend(config, argv);
