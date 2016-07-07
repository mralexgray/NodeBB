#!/usr/bin/env coffee


Service = require('node-mac').Service


p = require('path').join(__dirname,'nodebb')
n = 'NodeBB'
d = 'The 113w15 NodeBB web server'

console.log Service, p, n, d

# Create a new service object
svc = new Service name:n, description:d, script:p


# Listen for the "install" event, which indicates the
# process is available as a service.
svc.on 'install', ->
	svc.start()
