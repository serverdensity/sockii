// ex: set tabstop=4 shiftwidth=4 expandtab:

var fs = require('fs');
var _ = require('lodash');
var config = require('./config.js');
var forever = require('forever-monitor');

// Default config for forever-monitor
var foreverConfig = {
    max: 3,
    spinSleepTime: 5000,
    silent: false,
    killTree: true
};

// Allow config to be overridden by config file or command line args
foreverConfig = _.extend(foreverConfig, config.forever || {});
foreverConfig.options = process.argv.slice(2);

var child = new (forever.Monitor)(__dirname + '/init-sockii.js', foreverConfig);

child.on('exit', function () {
    console.error('[sockii-forever] init-sockii.js has exited after ' + foreverConfig.max +' restarts');
});

child.on('restart', function() {
    console.error('[sockii-forever] init-sockii.js child restarted');
});

child.on('start', function(childProcess) {
    process.on('SIGHUP', function () {
        childProcess.kill('SIGHUP');
        return false;
    });
});

process.on('uncaughtException', function (err) {
  console.error('[sockii-forever] caught exception: ' + err);
});

child.start();
