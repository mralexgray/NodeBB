 #!/usr/bin/env coffee

try
	[colors,cproc,fs,path,request,semver,prompt,async] =
		require x for x in ['colors','child_process','fs','path','request','semver','prompt','async']
	argv = require('minimist') process.argv.slice(2)
catch e
	if e.code is 'MODULE_NOT_FOUND'
		process.stdout.write """
			NodeBB could not be started because it's dependencies have not been installed.
			Please ensure that you have executed \"npm install --production\" prior to running NodeBB.

			For more information, please see: https://docs.nodebb.org/en/latest/installing/os.html

			Could not start: #{e.code}
		"""
		process.exit 1

getRunningPid = (callback) ->
	fs.readFile __dirname + '/pidfile', { encoding: 'utf-8' }, (err, pid) ->
		if err then return callback(err)
		try
			process.kill parseInt(pid, 10), 0
			callback null, parseInt(pid, 10)
		catch e
			callback e

getCurrentVersion = (callback) ->
	fs.readFile path.join(__dirname, 'package.json'), { encoding: 'utf-8' }, (err, pkg) ->
		try
			pkg = JSON.parse(pkg)
			return callback(null, pkg.version)
		catch err
			return callback(err)

fork = (args) -> cproc.fork 'app.js', args, { cwd: __dirname, silent: false }

getInstalledPlugins = (callback) ->
	async.parallel
		files: async.apply(fs.readdir, path.join(__dirname, 'node_modules'))
		deps: async.apply(fs.readFile, path.join(__dirname, 'package.json'), encoding: 'utf-8')
	, (err, payload) ->
		isNbbModule = /^nodebb-(?:plugin|theme|widget|rewards)-[\w\-]+$/
		moduleName = undefined
		isGitRepo = undefined
		payload.files = payload.files.filter (file) -> isNbbModule.test file
		try
			payload.deps = JSON.parse(payload.deps).dependencies
			payload.bundled = []
			payload.installed = []
		catch err
			return callback(err)
		for moduleName of payload.deps
			`moduleName = moduleName`
			if isNbbModule.test(moduleName) then payload.bundled.push moduleName
		# Whittle down deps to send back only extraneously installed plugins/themes/etc
		payload.files.forEach (moduleName) ->
			try
				fs.accessSync path.join(__dirname, 'node_modules/' + moduleName, '.git')
				isGitRepo = true
			catch e
				isGitRepo = false
			if payload.files.indexOf(moduleName) isnt -1 and
			payload.bundled.indexOf(moduleName) is -1 and
			not fs.lstatSync(path.join(__dirname, 'node_modules',moduleName)).isSymbolicLink() and
			not isGitRepo
				payload.installed.push moduleName
		getModuleVersions payload.installed, callback

getModuleVersions = (modules, callback) ->
	versionHash = {}
	async.eachLimit modules, 50, ((module, next) ->
		fs.readFile path.join(__dirname, 'node_modules/' + module + '/package.json'), { encoding: 'utf-8' }, (err, pkg) ->
			try
				pkg = JSON.parse(pkg)
				versionHash[module] = pkg.version
				next()
			catch err
				next err
	), (err) ->
		callback err, versionHash

checkPlugins = (standalone, callback) ->
	if standalone then process.stdout.write 'Checking installed plugins and themes for updates... '
	async.waterfall [
		async.apply(async.parallel,
			plugins: async.apply(getInstalledPlugins)
			version: async.apply(getCurrentVersion))
		(payload, next) ->
			toCheck = Object.keys(payload.plugins)
			if not toCheck.length
				process.stdout.write 'OK'.green + '\n'.reset
				return next(null, [])
				# no extraneous plugins installed
			request
				method: 'GET'
				url: "https://packages.nodebb.org/api/v1/suggest?version=#{payload.version}&package[]=#{toCheck.join('&package[]=')}"
				json: true
			, (err, res, body) ->
				if err
					process.stdout.write 'error'.red + '\n'.reset
					return next(err)
				process.stdout.write 'OK'.green + '\n'.reset
				if not Array.isArray(body) and toCheck.length is 1
					body = [ body ]
				current = undefined
				suggested = undefined
				upgradable = body.map((suggestObj) ->
					current = payload.plugins[suggestObj.package]
					suggested = suggestObj.version
					if suggestObj.code is 'match-found' and semver.gt(suggested, current)
						{
							name: suggestObj.package
							current: current
							suggested: suggested
						}
					else
						null
				).filter(Boolean)
				next null, upgradable
	], callback

upgradePlugins = (callback) ->
	standalone = false
	if typeof callback isnt 'function'
		callback = -> null
		standalone = true
	checkPlugins standalone, (err, found) ->
		if err
			process.stdout.write 'Warning'.yellow + ': An unexpected error occured when attempting to verify plugin upgradability\n'.reset
			return callback(err)
		if found and found.length
			process.stdout.write '\nA total of ' + new String(found.length).bold + ' package(s) can be upgraded:\n'
			found.forEach (suggestObj) ->
				process.stdout.write '  * '.yellow + suggestObj.name.reset + ' (' + suggestObj.current.yellow + ' -> '.reset + suggestObj.suggested.green + ')\n'.reset
			process.stdout.write '\n'
		else
			if standalone
				process.stdout.write '\nAll packages up-to-date!'.green + '\n'.reset
			return callback()
		prompt.message = ''
		prompt.delimiter = ''
		prompt.start()
		prompt.get {
			name: 'upgrade'
			description: 'Proceed with upgrade (y|n)?'.reset
			type: 'string'
		}, (err, result) ->
			if result.upgrade in ['y','Y','yes','YES']
				process.stdout.write '\nUpgrading packages...'
				args = ['npm','i']
				found.forEach (suggestObj) ->
					args.push suggestObj.name + '@' + suggestObj.suggested
					return
				require('child_process').execFile '/usr/bin/env', args, { stdio: 'ignore' }, (err) ->
					if not err then process.stdout.write ' OK\n'.green
					callback err
			else
				process.stdout.write '\nPackage upgrades skipped'.yellow + '. Check for upgrades at any time by running "'.reset + './nodebb upgrade-plugins'.green + '".\n'.reset
				callback()

switch process.argv[2]
	when 'status'
		getRunningPid (err, pid) ->
			if not err
				process.stdout.write '\nNodeBB Running '.bold + '(pid '.cyan + pid.toString().cyan + ')\n'.cyan
				process.stdout.write '	"' + './nodebb stop'.yellow + '" to stop the NodeBB server\n'
				process.stdout.write '	"' + './nodebb log'.yellow + '" to view server output\n'
				process.stdout.write '	"' + './nodebb restart'.yellow + '" to restart NodeBB\n\n'
			else
				process.stdout.write """
					#{'NodeBB is not running'.bold}
						#{'./nodebb start'.yellow} to launch the NodeBB server
				"""
			return
	when 'start'
		process.stdout.write """
		  #{'Starting NodeBB'.bold}
		  	\"#{'./nodebb stop'.yellow}\" to stop the NodeBB server
		  	\"#{'./nodebb log'.yellow}\" to view server output
		  	\"#{'./nodebb restart'.yellow}\" to restart NodeBB
		"""
		# Spawn a new NodeBB process
		cproc.fork __dirname + '/loader.js', env: process.env
	when 'stop'
		getRunningPid (err, pid) ->
			if not err
				process.kill pid, 'SIGTERM'
				process.stdout.write 'Stopping NodeBB. Goodbye!\n'
			else
				process.stdout.write 'NodeBB is already stopped.\n'
			return
	when 'restart'
		getRunningPid (err, pid) ->
			if not err
				process.kill pid, 'SIGHUP'
				process.stdout.write '\nRestarting NodeBB\n'.bold
			else
				process.stdout.write 'NodeBB could not be restarted, as a running instance could not be found.\n'
			return
	when 'reload'
		getRunningPid (err, pid) ->
			if not err then process.kill pid, 'SIGUSR2'
			else process.stdout.write 'NodeBB could not be reloaded, as a running instance could not be found.\n'
	when 'dev'
		process.env.NODE_ENV = 'development'
		cproc.fork __dirname + '/loader.coffee', [
			'--no-daemon'
			'--no-silent'
		], env: process.env
	when 'log'
		process.stdout.write "#{'Type '.red} #{'Ctrl-C '.bold}'#{'to exit'.red}"
		cproc.spawn 'tail', [
			'-F'
			'./logs/output.log'
		],
			cwd: __dirname
			stdio: 'inherit'
	when 'setup'
		cproc.fork 'app.js', [ '--setup' ],
			cwd: __dirname
			silent: false
	when 'reset'
		args = process.argv.slice(0)
		args.unshift '--reset'
		fork args
	when 'activate'
		args = process.argv.slice(0)
		args.unshift '--activate'
		fork args
	when 'plugins'
		args = process.argv.slice(0)
		args.unshift '--plugins'
		fork args
	when 'upgrade-plugins'
		upgradePlugins()
	when 'upgrade'
		async.series [
			(next) ->
				process.stdout.write '1. '.bold + 'Bringing base dependencies up to date... '.yellow
				require('child_process').execFile '/usr/bin/env', [
					'npm'
					'i'
					'--production'
				], { stdio: 'ignore' }, next
				return
			(next) ->
				process.stdout.write """
					#{'OK'.green}
					#{'2. '.bold}#{'Checking installed plugins for updates... '.yellow}
				"""
				upgradePlugins next
			(next) ->
				process.stdout.write "#{'3.'.bold} #{'Updating NodeBB data store schema...\n'.yellow}"
				upgradeProc = cproc.fork('app.js', [ '--upgrade' ],
					cwd: __dirname
					silent: false)
				upgradeProc.on 'close', next
		], (err) ->
			if err then process.stdout.write "\n#{'Error'.red}: #{err.message}\n"
			else
				message = 'NodeBB Upgrade Complete!'
				# some consoles will return undefined/zero columns, so just use 2 spaces in upgrade script if we can't get our column count
				columns = process.stdout.columns
				spaces = if columns then new Array(Math.floor(columns / 2) - (message.length / 2) + 1).join(' ') else '  '
				process.stdout.write 'OK\n'.green
				process.stdout.write '\n' + spaces + message.green.bold + '\n\n'.reset
	else
		process.stdout.write """
			#{'Welcome to NodeBB'.bold}

			Usage: ./nodebb {start|stop|reload|restart|log|setup|reset|upgrade|dev}

				#{'start'.yellow}	Start the NodeBB server
				#{'stop'.yellow}	Stops the NodeBB server
				#{'reload'.yellow}	Restarts NodeBB
				#{'restart'.yellow}	Restarts NodeBB
				#{'log'.yellow}	Opens the logging interface (useful for debugging)
				#{'setup'.yellow}	Runs the NodeBB setup script
				#{'reset'.yellow}	Disables all plugins, restores the default theme.
				#{'activate'.yellow}	Activate a plugin on start up.
				#{'plugins'.yellow}	List all plugins that have been installed.
				#{'upgrade'.yellow}	Run NodeBB upgrade scripts, ensure packages are up-to-date
				#{'dev'.yellow}	Start NodeBB in interactive development mode
		"""
		break
