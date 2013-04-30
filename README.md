# sockii

HTTP and WebSocket aggregation thinlayer, which acts as a proxy between a frontend UI and multiple backend HTTP services.

See this [blog post](http://blog.serverdensity.com/introducing-sockii-http-and-websocket-aggregator/) for more info.

## Installing

Install it via [npm](https://npmjs.org/):

```bash
npm install -g sockii
```

Or by downloading the repository and building it with `npm`:

```bash
git checkout https://github.com/serverdensity/sockii.git
cd sockii
npm install
```

## Usage

The documentation is a work in progress, but for now you can look at the [example config](config/example.json) for pointers on how to configure the app.

Basic usage, if system installed:

```bash
cd $MYAPPDIR
sockii --help
sockii -c ./myapp.json
```

If using a local build:

```bash
cd sockii
./bin/sockii --help
./bin/sockii -c $MYAPPDIR/myapp.json
```
