express = require("express")
bodyParser = require "body-parser"
app = express()

module.exports = MockClsiApi =
	run: () ->

		compile = (req, res, next) =>
			res.status(200).send {
				compile:
					status: 'success'
					error: null
					outputFiles: [
						url: "/project/#{req.params.project_id}/build/1234/output/project.pdf"
						path: 'project.pdf'
						type: 'pdf'
						build: 1234
					,
						url: "/project/#{req.params.project_id}/build/1234/output/project.log"
						path: 'project.log'
						type: 'log'
						build: 1234
					]
			}

		app.post "/project/:project_id/compile", compile
		app.post "/project/:project_id/user/:user_id/compile", compile

		app.get "/project/:project_id/build/:build_id/output/*", (req, res, next) ->
			filename = req.params[0]
			if filename == 'project.pdf'
				res.status(200).send 'mock-pdf'
			else if filename == 'project.log'
				res.status(200).send 'mock-log'
			else
				res.sendStatus(404)

		app.get "/project/:project_id/user/:user_id/build/:build_id/output/:output_path", (req, res, next) =>
			res.status(200).send("hello")

		app.get "/project/:project_id/status", (req, res, next) =>
			res.status(200).send()

		app.listen 3013, (error) ->
			throw error if error?
		.on "error", (error) ->
			console.error "error starting MockClsiApi:", error.message
			process.exit(1)

MockClsiApi.run()
