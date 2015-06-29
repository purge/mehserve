async = require 'async'
express = require 'express'
fs = require 'fs'
httpProxy = require 'http-proxy'
request = require 'request'

CONFIG_DIR="#{process.env.HOME}/.mehserve"
PORT = process.env.PORT ? 12439
SUFFIXES=[".dev", ".meh"]

readConfig = (req, res, next) ->
  async.waterfall [
    # Determine host from header
    (done) ->
      host = req.headers.host
      for suffix in SUFFIXES
        endOfHost = host.substr(host.length - suffix.length)
        if endOfHost.toLowerCase() is suffix.toLowerCase()
          host = host.substr(0, host.length - suffix.length)
          break
      done null, host

    # Determine which config to use
    (host, done) ->
      split = host.split(".")
      options = []
      for i in [0...split.length]
        options.push split[split.length - i - 1..].join(".")
      options.push "default"
      exists = (option, done) ->
        fs.exists "#{CONFIG_DIR}/#{option}", done
      async.detectSeries options, exists, (configName) ->
        return done null, configName if configName
        err = new Error "Configuration not found"
        err.code = 500
        done err

    # Get stats
    (configName, done) ->
      fs.stat "#{CONFIG_DIR}/#{configName}", (err, stats) ->
        done(err, configName, stats)

    # Interpret stats
    (configName, stats, done) ->
      if stats.isDirectory()
        config =
          type: 'static'
          path: "#{CONFIG_DIR}/#{configName}"
      else
        contents = fs.readFileSync("#{CONFIG_DIR}/#{configName}", 'utf8')
        if contents[0] is "{"
          config = JSON.parse(contents)
        else
          lines = contents.split("\n")
          if lines[0].match(/^[0-9]+$/)
            config =
              type: 'port'
              port: parseInt(lines[0], 10)
          else if lines[0].match(/^\//)
            config =
              type: 'static'
              path: "#{lines[0]}"
          else
            config = {}
      done null, config

  ], (err, config) ->
    return next err if err
    req.config = config
    next()

handle = (req, res, next) ->
  if req.config.type is 'port'
    forward(req, res, next)
  else if req.config.type is 'static'
    serve(req, res, next)
  else
    err = new Error "Config not understood"
    err.code = 500
    err.meta = req.config
    next err

staticMiddlewares = {}
serve = (req, res, next) ->
  config = req.config
  path = config.path
  staticMiddlewares[path] ?= express.static(path)
  staticMiddlewares[path](req, res, next)


proxy = httpProxy.createProxyServer {host: "localhost", ws: true}
forward = (req, res, next) ->
  config = req.config
  port = config.port
  proxy.web req, res, {target: {port: port}}, next

upgrade = (req, socket, head) ->
  readConfig req, null, (err) ->
    return socket.close() if err
    config = req.config
    port = config.port
    proxy.ws req, socket, head, {target: {port: port}}


server = express()
server.use readConfig
server.use handle

httpServer = server.listen PORT, ->
  port = httpServer.address().port

httpServer.on 'upgrade', upgrade

dnsServer = require './dnsserver'
dnsServer.serve 15353
