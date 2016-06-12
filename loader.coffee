forkWorker = (index, isPrimary) ->
	ports = getPorts()
	if not ports[index]
		return console.log('[cluster] invalid port for worker : ' + index + ' ports: ' + ports.length)
	process.env.isPrimary = isPrimary
	process.env.isCluster = if ports.length > 1 then true else false
	process.env.port = ports[index]
	worker = fork('app.js', [],
		silent: silent
		env: process.env)
	worker.index = index
	worker.isPrimary = isPrimary
	workers[index] = worker
	Loader.addWorkerEvents worker
	if silent
		output = logrotate(
			file: __dirname + '/logs/output.log'
			size: '1m'
			keep: 3
			compress: true)
		worker.stdout.pipe output
		worker.stderr.pipe output

getPorts = ->
	_url = nconf.get('url')
	if not _url
		console.log '[cluster] url is undefined, please check your config.json'
		process.exit()
	urlObject = url.parse(_url)
	port = nconf.get('port') or nconf.get('PORT') or urlObject.port or 4567
	if not Array.isArray(port)
		port = [ port ]
	port

killWorkers = ->
	workers.forEach (worker) ->
		worker.suicide = true
		worker.kill()

'use strict'
nconf = require('nconf')
fs = require('fs')
url = require('url')
path = require('path')
fork = require('child_process').fork
async = require('async')
logrotate = require('logrotate-stream')
file = require('./src/file')
pkg = require('./package.json')
nconf.argv().env().file file: path.join(__dirname, '/config.json')
pidFilePath = __dirname + '/pidfile'
output = logrotate(
	file: __dirname + '/logs/output.log'
	size: '1m'
	keep: 3
	compress: true)
silent = if nconf.get('silent') is 'false' then false else nconf.get('silent') isnt false
numProcs = undefined
workers = []
Loader =
	timesStarted: 0
	js: target: {}
	css:
		cache: undefined
		acpCache: undefined

Loader.init = (callback) ->
	if silent

		console.log = ->
			args = Array::slice.call(arguments)
			output.write args.join(' ') + '\n'
			return

	process.on 'SIGHUP', Loader.restart
	process.on 'SIGUSR2', Loader.reload
	process.on 'SIGTERM', Loader.stop
	callback()
	return

Loader.displayStartupMessages = (callback) ->
	console.log ''
	console.log 'NodeBB v' + pkg.version + ' Copyright (C) 2013-2014 NodeBB Inc.'
	console.log 'This program comes with ABSOLUTELY NO WARRANTY.'
	console.log 'This is free software, and you are welcome to redistribute it under certain conditions.'
	console.log 'For the full license, please visit: http://www.gnu.org/copyleft/gpl.html'
	console.log ''
	callback()
	return

Loader.addWorkerEvents = (worker) ->
	worker.on 'exit', (code, signal) ->
		if code isnt 0
			if Loader.timesStarted < numProcs * 3
				Loader.timesStarted++
				if Loader.crashTimer
					clearTimeout Loader.crashTimer
				Loader.crashTimer = setTimeout((->
					Loader.timesStarted = 0
					return
				), 10000)
			else
				console.log numProcs * 3 + ' restarts in 10 seconds, most likely an error on startup. Halting.'
				process.exit()
		console.log '[cluster] Child Process (' + worker.pid + ') has exited (code: ' + code + ', signal: ' + signal + ')'
		if not (worker.suicide or code is 0)
			console.log '[cluster] Spinning up another process...'
			forkWorker worker.index, worker.isPrimary
	worker.on 'message', (message) ->
		if message and typeof message == 'object' and message.action
			switch message.action
				when 'ready'
					if Loader.js.target['nodebb.min.js'] and Loader.js.target['nodebb.min.js'].cache and !worker.isPrimary
						worker.send
							action: 'js-propagate'
							cache: Loader.js.target['nodebb.min.js'].cache
							map: Loader.js.target['nodebb.min.js'].map
							target: 'nodebb.min.js'
					if Loader.js.target['acp.min.js'] and Loader.js.target['acp.min.js'].cache and !worker.isPrimary
						worker.send
							action: 'js-propagate'
							cache: Loader.js.target['acp.min.js'].cache
							map: Loader.js.target['acp.min.js'].map
							target: 'acp.min.js'
					if Loader.css.cache and !worker.isPrimary
						worker.send
							action: 'css-propagate'
							cache: Loader.css.cache
							acpCache: Loader.css.acpCache
				when 'restart'
					console.log '[cluster] Restarting...'
					Loader.restart()
				when 'reload'
					console.log '[cluster] Reloading...'
					Loader.reload()
				when 'js-propagate'
					Loader.js.target = message.data
					Loader.notifyWorkers {
						action: 'js-propagate'
						data: message.data
					}, worker.pid
				when 'css-propagate'
					Loader.css.cache = message.cache
					Loader.css.acpCache = message.acpCache
					Loader.notifyWorkers {
						action: 'css-propagate'
						cache: message.cache
						acpCache: message.acpCache
					}, worker.pid
				when 'templates:compiled'
					Loader.notifyWorkers { action: 'templates:compiled' }, worker.pid

Loader.start = (callback) ->
	numProcs = getPorts().length
	console.log 'Clustering enabled: Spinning up ' + numProcs + ' process(es).\n'
	x = 0
	while x < numProcs
		forkWorker x, x == 0
		++x
	if callback
		callback()

Loader.restart = ->
	killWorkers()
	Loader.start()

Loader.reload = ->
	workers.forEach (worker) ->
		worker.send action: 'reload'

Loader.stop = ->
	killWorkers()
	# Clean up the pidfile
	fs.unlinkSync __dirname + '/pidfile'

Loader.notifyWorkers = (msg, worker_pid) ->
	worker_pid = parseInt(worker_pid, 10)
	workers.forEach (worker) ->
		if parseInt(worker.pid, 10) != worker_pid
			try
				worker.send msg
			catch e
				console.log '[cluster/notifyWorkers] Failed to reach pid ' + worker_pid

fs.open path.join(__dirname, 'config.json'), 'r', (err) ->
	if !err
		if nconf.get('daemon') != 'false' and nconf.get('daemon') != false
			if file.existsSync(pidFilePath)
				try
					pid = fs.readFileSync(pidFilePath, encoding: 'utf-8')
					process.kill pid, 0
					process.exit()
				catch e
					fs.unlinkSync pidFilePath
			require('daemon')
				stdout: process.stdout
				stderr: process.stderr
			fs.writeFile __dirname + '/pidfile', process.pid
		async.series [
			Loader.init
			Loader.displayStartupMessages
			Loader.start
		], (err) ->
			if err
				console.log '[loader] Error during startup: ' + err.message
	else
		# No config detected, kickstart web installer
		child = require('child_process').fork('app')
