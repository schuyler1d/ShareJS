# This implements the socketio-based network API for ShareJS.
#
# This is the frontend used by the javascript client implementation.
#
# See documentation for this protocol is in doc/protocol.md
# Tests are in test/socketio.coffee

io = require 'socket.io'
util = require 'util'

p = -> #util.debug
i = -> #util.inspect

# Attach the streaming protocol to the supplied http.Server.
#
# Options = {}
exports.attach = (server, model, options) ->
	socket = io.listen server, {log: null}

	socket.on 'connection', (client) ->
		# There seems to be a bug in socket.io where client.request isn't set sometimes.
		p "New client connected from #{client.request.socket.remoteAddress} with sessionId #{client.sessionId}" if client.request?

		lastSentDoc = null
		lastReceivedDoc = null

		# Map from docName -> {listener:fn, queue:[msg], busy:bool}
		docState = {}
		closed = false

		# Send a message to the client.
		# msg _must_ have the doc:DOCNAME property set. We'll remove it if its the same as lastReceivedDoc.
		send = (msg) ->
			if msg.doc == lastSentDoc
				delete msg.doc
			else
				lastSentDoc = msg.doc

			p "Sending #{i msg}"
			client.send msg

		# Open the given document name, at the requested version.
		# callback(opened at version, [error])
		open = (docName, version, callback) ->
			callback null, 'Doc already opened' if docState[docName].listener?
			p "Registering listener on #{docName} by #{client.sessionId} at #{version}"

			docState[docName].listener = listener = (opData) ->
				throw new Error 'Consistency violation - doc listener invalid' unless docState[docName].listener == listener

				p "listener doc:#{docName} opdata:#{i opData} v:#{version}"

				# Skip the op if this client sent it.
				return if opData.meta?.source == client.sessionId != undefined

				opMsg =
					doc: docName
					op: opData.op
					v: opData.v
					meta: opData.meta

				send opMsg

			openedAt = (version) ->
				if version == null
					callback null, 'Document does not exist'
				else
					callback version
				return
			
			if version?
				# Tell the client the doc is open at the requested version
				model.clientListenFromVersion client, docName, version, listener, openedAt
			else
				# If the version is blank, we'll open the doc at the most recent version
				model.clientListen client, docName, listener, openedAt

		# Close the named document.
		# callback([error])
		close = (docName, callback) ->
			p "Closing #{docName}"
			listener = docState[docName].listener
			unless listener?
				callback 'Doc already closed'
				return

			model.removeListener docName, listener
			docState[docName].listener = null
			callback()

		# Handles messages with any combination of the open:true, create:true and snapshot:null parameters
		handleOpenCreateSnapshot = (query, callback) ->
			throw new Error 'No docName specified' unless query.doc?

			if query.create == true
				if typeof query.type != 'string'
					throw new Error 'create:true requires type specified'

			if query.meta != undefined
				unless typeof query.meta == 'object' and Array.isArray(query.meta) == false
					throw new Error 'meta must be an object'

			docName = query.doc
			msg = doc:docName

			fail = (errorMsg) ->
				close(docName) if msg.open == true
				msg.open = false if query.open == true
				msg.snapshot = null if query.snapshot != undefined
				delete msg.create

				msg.error = errorMsg
				send msg

			# This is implemented with a series of cascading methods for each different type of
			# thing this method can handle. This would be so much nicer with an async library. Welcome to
			# callback hell.

			step1Create = ->
				if query.create != true
					step2Snapshot()
					return

				# The document obviously already exists if we have a snapshot.
				if docData
					msg.create = false
					step2Snapshot()
				else
					model.clientCreate client, docName, query.type, query.meta || {}, (result, errorMsg) ->
						if errorMsg? and errorMsg != 'Document already exists'
							fail errorMsg
							return

						msg.create = result
						step2Snapshot()

			# The client requested a document snapshot
			step2Snapshot = ->
				# Skip inserting a snapshot if the document was just created.
				if query.snapshot != null or msg.create == true
					step3Open()
					return

				if docData
					msg.v = docData.v
					msg.type = docData.type.name unless query.type == docData.type.name
					msg.snapshot = docData.snapshot
				else
					fail 'Document does not exist'
					return

				step3Open()

			# Attempt to open a document with a given name. Version is optional.
			# callback(opened at version) or callback(null, errormessage)
			step3Open = ->
				if query.open != true
					finish()
					return

				if query.type and docData != null and query.type != docData.type.name
					# Verify the type matches
					fail 'Type mismatch'
					return

				open docName, query.v, (version, error) ->
					if error
						fail error
					else
						# + Should fail if the type is wrong.

						p "Opened #{docName} at #{version} by #{client.sessionId}"
						msg.open = true
						msg.v = version
						finish()

			finish = ->
				send msg
				callback()

			docData = undefined
			if query.snapshot == null or (query.open == true and query.type)
				model.clientGetSnapshot client, query.doc, (d, errorMsg) ->
					if errorMsg? and errorMsg != 'Document does not exist'
						fail errorMsg
						return
					else
						docData = d
						step1Create()
			else
				step1Create()

		# The client closes a document
		handleClose = (query, callback) ->
			close query.doc, (error) ->
				if error
					# An error closing still results in the doc being closed.
					send {doc:query.doc, open:false, error:error}
				else
					send {doc:query.doc, open:false}

				callback()

		# We received an op from the client
		handleOp = (query, callback) ->
			throw new Error 'No docName specified' unless query.doc?
			throw new Error 'No version specified' unless query.v?

			op_data = {v:query.v, op:query.op}
			op_data.meta = query.meta || {}
			op_data.meta.source = client.sessionId

			model.clientSubmitOp client, query.doc, op_data, (appliedVersion, error) ->
				msg = if error?
					p "Sending error to client: #{error}"
					{doc:query.doc, v:null, error: error}
				else
					{doc:query.doc, v:appliedVersion}

				send msg
				callback()

		flush = (state) ->
			return if state.busy || state.queue.length == 0
			state.busy = true

			query = state.queue.shift()

			callback = ->
				state.busy = false
				flush state

			p "processing query #{i query}"
			try
				if query.open == false
					handleClose query, callback

				else if query.open != undefined or query.snapshot != undefined or query.create
					# You can open, request a snapshot and create all in the same
					# request. They're all handled together.
					handleOpenCreateSnapshot query, callback

				else if query.op? # The client is applying an op.
					handleOp query, callback

				else
					util.debug "Unknown message received: #{util.inspect query}"

			catch error
				util.debug error.stack
				# ... And disconnect the client?
				callback()
		
		# And now the actual message handler.
		messageListener = (query) ->
			# There seems to be a bug in socket.io where messages are detected
			# after the client disconnects.
			if closed
				console.log "WARNING: received query from client after the client disconnected."
				console.log client
				return

			try
				query = JSON.parse query if typeof(query) == 'string'

				if query.doc == null
					lastReceivedDoc = null
					query.doc = model.randomDocName()
				else if query.doc != undefined
					lastReceivedDoc = query.doc
				else
					throw new Error 'msg.doc missing' unless lastReceivedDoc
					query.doc = lastReceivedDoc
			catch error
				util.debug error.stack
				return

			docState[query.doc] ||= {listener:null, queue:[], busy:no}
			docState[query.doc].queue.push query
			flush docState[query.doc]

		client.on 'message', messageListener
		client.on 'disconnect', ->
			p "client #{client.sessionId} disconnected"
			closed = true
			for docName, state of docState
				state.busy = true
				state.queue = []
				model.removeListener docName, state.listener if state.listener?
			client.removeListener 'message', messageListener
			docState = {}
	
	server
