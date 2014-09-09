// ex: set tabstop=4 shiftwidth=4 expandtab:

var coffee = require('../node_modules/coffee-script/lib/coffee-script/coffee-script.js');
var fs = require('fs');
var Sockii = require('./sockii');

var config = require('./config.js');

// Write the PID file for this process
if (!config['from-forever'])
{
    fs.writeFileSync(argv.p, process.pid);
}

var sockii = new Sockii(config, config.configPath);
var delayStart = config.delayStart || 0;
var start = function() { sockii.listen(); };

if (delayStart > 0) {
    setTimeout(start, delayStart);
} else {
    start();
}
