define [
	"base"
	"ace/ace"
	"ace/ext-searchbox"
	"ace/ext-modelist"
	"ace/keybinding-vim"
	"ide/editor/directives/aceEditor/undo/UndoManager"
	"ide/editor/directives/aceEditor/auto-complete/AutoCompleteManager"
	"ide/editor/directives/aceEditor/spell-check/SpellCheckManager"
	"ide/editor/directives/aceEditor/spell-check/SpellCheckAdapter"
	"ide/editor/directives/aceEditor/highlights/HighlightsManager"
	"ide/editor/directives/aceEditor/cursor-position/CursorPositionManager"
	"ide/editor/directives/aceEditor/cursor-position/CursorPositionAdapter"
	"ide/editor/directives/aceEditor/track-changes/TrackChangesManager"
	"ide/editor/directives/aceEditor/metadata/MetadataManager"
	"ide/metadata/services/metadata"
	"ide/graphics/services/graphics"
	"ide/preamble/services/preamble"
	"ide/files/services/files"
], (App, Ace, SearchBox, Vim, ModeList, UndoManager, AutoCompleteManager, SpellCheckManager, SpellCheckAdapter, HighlightsManager, CursorPositionManager, CursorPositionAdapter, TrackChangesManager, MetadataManager) ->
	EditSession = ace.require('ace/edit_session').EditSession
	ModeList = ace.require('ace/ext/modelist')
	Vim = ace.require('ace/keyboard/vim').Vim

	# set the path for ace workers if using a CDN (from editor.pug)
	if window.aceWorkerPath != ""
		syntaxValidationEnabled = true
		ace.config.set('workerPath', "#{window.aceWorkerPath}")
	else
		syntaxValidationEnabled = false

	# By default, don't use workers - enable them per-session as required
	ace.config.setDefaultValue("session", "useWorker", false)

	# Ace loads its script itself, so we need to hook in to be able to clear
	# the cache.
	if !ace.config._moduleUrl?
		ace.config._moduleUrl = ace.config.moduleUrl
		ace.config.moduleUrl = (args...) ->
			url = ace.config._moduleUrl(args...)
			return url

	App.directive "aceEditor", ($timeout, $compile, $rootScope, event_tracking, localStorage, $cacheFactory, metadata, graphics, preamble, files, $http, $q, $window) ->
		monkeyPatchSearch($rootScope, $compile)

		return  {
			scope: {
				theme: "="
				showPrintMargin: "="
				keybindings: "="
				fontSize: "="
				autoComplete: "="
				autoPairDelimiters: "="
				sharejsDoc: "="
				spellCheck: "="
				spellCheckLanguage: "="
				highlights: "="
				text: "="
				readOnly: "="
				annotations: "="
				navigateHighlights: "="
				fileName: "="
				onCtrlEnter: "="   # Compile
				onCtrlJ: "="       # Toggle the review panel
				onCtrlShiftC: "="  # Add a new comment
				onCtrlShiftA: "="  # Toggle track-changes on/off
				onSave: "="        # Cmd/Ctrl-S or :w in Vim
				syntaxValidation: "="
				reviewPanel: "="
				eventsBridge: "="
				trackChanges: "="
				trackChangesEnabled: "="
				docId: "="
				rendererData: "="
				lineHeight: "="
				fontFamily: "="
			}
			link: (scope, element, attrs) ->
				# Don't freak out if we're already in an apply callback
				scope.$originalApply = scope.$apply
				scope.$apply = (fn = () ->) ->
					phase = @$root.$$phase
					if (phase == '$apply' || phase == '$digest')
						fn()
					else
						@$originalApply(fn);

				editor = ace.edit(element.find(".ace-editor-body")[0])
				editor.$blockScrolling = Infinity

				# auto-insertion of braces, brackets, dollars
				editor.setOption('behavioursEnabled', scope.autoPairDelimiters || false)
				editor.setOption('wrapBehavioursEnabled', false)

				scope.$watch "autoPairDelimiters", (autoPairDelimiters) =>
					if autoPairDelimiters
						editor.setOption('behavioursEnabled', true)
					else
						editor.setOption('behavioursEnabled', false)

				window._debug_editors ||= []
				window._debug_editors.push editor

				scope.name = attrs.aceEditor

				if scope.spellCheck # only enable spellcheck when explicitly required
					spellCheckCache = $cacheFactory.get("spellCheck-#{scope.name}") || $cacheFactory("spellCheck-#{scope.name}", {capacity: 1000})
					spellCheckManager = new SpellCheckManager(scope, spellCheckCache, $http, $q, new SpellCheckAdapter(editor))

				undoManager           = new UndoManager(scope, editor, element)
				highlightsManager     = new HighlightsManager(scope, editor, element)
				cursorPositionManager = new CursorPositionManager(scope, new CursorPositionAdapter(editor), localStorage)
				trackChangesManager   = new TrackChangesManager(scope, editor, element)
				metadataManager = new MetadataManager(scope, editor, element, metadata)
				autoCompleteManager = new AutoCompleteManager(scope, editor, element, metadataManager, graphics, preamble, files)

				scope.$watch "onSave", (callback) ->
					if callback?
						Vim.defineEx 'write', 'w', callback
						editor.commands.addCommand
							name: "save",
							bindKey: win: "Ctrl-S", mac: "Command-S"
							exec: callback
							readOnly: true
						# Not technically 'save', but Ctrl-. recompiles in OL v1
						# so maintain compatibility
						editor.commands.addCommand
							name: "recompile_v1",
							bindKey: win: "Ctrl-.", mac: "Ctrl-."
							exec: callback
							readOnly: true
				editor.commands.removeCommand "transposeletters"
				editor.commands.removeCommand "showSettingsMenu"
				editor.commands.removeCommand "foldall"


				# For European keyboards, the / is above 7 so needs Shift pressing.
				# This comes through as Command-Shift-/ on OS X, which is mapped to
				# toggleBlockComment.
				# This doesn't do anything for LaTeX, so remap this to togglecomment to
				# work for European keyboards as normal.
				# On Windows, the key combo comes as Ctrl-Shift-7.
				editor.commands.removeCommand "toggleBlockComment"
				editor.commands.removeCommand "togglecomment"

				editor.commands.addCommand {
					name: "togglecomment",
					bindKey: { win: "Ctrl-/|Ctrl-Shift-7", mac: "Command-/|Command-Shift-/" },
					exec: (editor) -> editor.toggleCommentLines(),
					multiSelectAction: "forEachLine",
					scrollIntoView: "selectionPart"
				}

				# Trigger search AND replace on CMD+F
				editor.commands.addCommand
					name: "find",
					bindKey: win: "Ctrl-F", mac: "Command-F"
					exec: (editor) ->
						ace.require("ace/ext/searchbox").Search(editor, true)
					readOnly: true

				# Bold text on CMD+B
				editor.commands.addCommand
					name: "bold",
					bindKey: win: "Ctrl-B", mac: "Command-B"
					exec: (editor) ->
						selection = editor.getSelection()
						if selection.isEmpty()
							editor.insert("\\textbf{}")
							editor.navigateLeft(1)
						else
							text = editor.getCopyText()
							editor.insert("\\textbf{" + text + "}")
					readOnly: false

				# Italicise text on CMD+I
				editor.commands.addCommand
					name: "italics",
					bindKey: win: "Ctrl-I", mac: "Command-I"
					exec: (editor) ->
						selection = editor.getSelection()
						if selection.isEmpty()
							editor.insert("\\textit{}")
							editor.navigateLeft(1)
						else
							text = editor.getCopyText()
							editor.insert("\\textit{" + text + "}")
					readOnly: false

				scope.$watch "onCtrlEnter", (callback) ->
					if callback?
						editor.commands.addCommand
							name: "compile",
							bindKey: win: "Ctrl-Enter", mac: "Command-Enter"
							exec: (editor) =>
								callback()
							readOnly: true

				scope.$watch "onCtrlJ", (callback) ->
					if callback?
						editor.commands.addCommand
							name: "toggle-review-panel",
							bindKey: win: "Ctrl-J", mac: "Command-J"
							exec: (editor) =>
								callback()
							readOnly: true

				scope.$watch "onCtrlShiftC", (callback) ->
					if callback?
						editor.commands.addCommand
							name: "add-new-comment",
							bindKey: win: "Ctrl-Shift-C", mac: "Command-Shift-C"
							exec: (editor) =>
								callback()
							readOnly: true

				scope.$watch "onCtrlShiftA", (callback) ->
					if callback?
						editor.commands.addCommand
							name: "toggle-track-changes",
							bindKey: win: "Ctrl-Shift-A", mac: "Command-Shift-A"
							exec: (editor) =>
								callback()
							readOnly: true

				# Make '/' work for search in vim mode.
				editor.showCommandLine = (arg) =>
					if arg == "/"
						ace.require("ace/ext/searchbox").Search(editor, true)

				getCursorScreenPosition = () ->
					session = editor.getSession()
					cursorPosition = session.selection.getCursor()
					sessionPos = session.documentToScreenPosition(cursorPosition.row, cursorPosition.column)
					screenPos = editor.renderer.textToScreenCoordinates(sessionPos.row, sessionPos.column)
					return sessionPos.row * editor.renderer.lineHeight - session.getScrollTop()

				if attrs.resizeOn?
					for event in attrs.resizeOn.split(",")
						scope.$on event, () ->
							previousScreenPosition = getCursorScreenPosition()
							editor.resize()
							# Put cursor back to same vertical position on screen
							newScreenPosition = getCursorScreenPosition()
							session = editor.getSession()
							session.setScrollTop(session.getScrollTop() + newScreenPosition - previousScreenPosition)

				scope.$on "#{scope.name}:set-scroll-size", (e, size) ->
					# Make sure that the editor has enough scroll margin above and below
					# to scroll the review panel with the given size
					marginTop = size.overflowTop
					maxHeight = editor.renderer.layerConfig.maxHeight
					marginBottom = Math.max(size.height - maxHeight, 0)
					setScrollMargins(marginTop, marginBottom)

				setScrollMargins = (marginTop, marginBottom) ->
					marginChanged = false
					if editor.renderer.scrollMargin.top != marginTop
						editor.renderer.scrollMargin.top = marginTop
						marginChanged = true
					if editor.renderer.scrollMargin.bottom != marginBottom
						editor.renderer.scrollMargin.bottom = marginBottom
						marginChanged = true
					if marginChanged
						editor.renderer.updateFull()

				resetScrollMargins = () ->
					setScrollMargins(0,0)

				scope.$watch "theme", (value) ->
					editor.setTheme("ace/theme/#{value}")

				scope.$watch "showPrintMargin", (value) ->
					editor.setShowPrintMargin(value)

				scope.$watch "keybindings", (value) ->
					if value in ["vim", "emacs"]
						editor.setKeyboardHandler("ace/keyboard/#{value}")
					else
						editor.setKeyboardHandler(null)

				scope.$watch "fontSize", (value) ->
					element.find(".ace_editor, .ace_content").css({
						"font-size": value + "px"
					})

				scope.$watch "fontFamily", (value) ->
					if value?
						switch value
							when 'monaco'
								editor.setOption('fontFamily', '"Monaco", "Menlo", "Ubuntu Mono", "Consolas", "source-code-pro", monospace')
							when 'lucida'
								editor.setOption('fontFamily', '"Lucida Console", monospace')
							else
								editor.setOption('fontFamily', null)

				scope.$watch "lineHeight", (value) ->
					if value?
						switch value
							when 'compact'
								editor.container.style.lineHeight = 1.33
							when 'normal'
								editor.container.style.lineHeight = 1.6
							when 'wide'
								editor.container.style.lineHeight = 2
							else
								editor.container.style.lineHeight = 1.6
						editor.renderer.updateFontSize()

				scope.$watch "sharejsDoc", (sharejs_doc, old_sharejs_doc) ->
					if old_sharejs_doc?
						scope.$broadcast('beforeChangeDocument')
						detachFromAce(old_sharejs_doc)
					if sharejs_doc?
						attachToAce(sharejs_doc)
					if sharejs_doc? and old_sharejs_doc?
						scope.$broadcast('afterChangeDocument')

				scope.$watch "text", (text) ->
					if text?
						editor.setValue(text, -1)
						session = editor.getSession()
						session.setUseWrapMode(true)

				scope.$watch "annotations", (annotations) ->
					session = editor.getSession()
					session.setAnnotations annotations

				scope.$watch "readOnly", (value) ->
					editor.setReadOnly !!value

				scope.$watch "syntaxValidation", (value) ->
					# ignore undefined settings here
					# only instances of ace with an explicit value should set useWorker
					# the history instance will have syntaxValidation undefined
					if value? and syntaxValidationEnabled
						session = editor.getSession()
						session.setOption("useWorker", value);

				editor.setOption("scrollPastEnd", true)

				updateCount = 0
				onChange = () ->
					updateCount++

					if updateCount == 100
						event_tracking.send 'editor-interaction', 'multi-doc-update'
					scope.$emit "#{scope.name}:change"

				onScroll = (scrollTop) ->
					return if !scope.eventsBridge?
					height = editor.renderer.layerConfig.maxHeight
					scope.eventsBridge.emit "aceScroll", scrollTop, height

				onScrollbarVisibilityChanged = (event, vRenderer) ->
					return if !scope.eventsBridge?
					scope.eventsBridge.emit "aceScrollbarVisibilityChanged", vRenderer.scrollBarV.isVisible, vRenderer.scrollBarV.width

				if scope.eventsBridge?
					editor.renderer.on "scrollbarVisibilityChanged", onScrollbarVisibilityChanged

					scope.eventsBridge.on "externalScroll", (position) ->
						editor.getSession().setScrollTop(position)
					scope.eventsBridge.on "refreshScrollPosition", () ->
						session = editor.getSession()
						session.setScrollTop(session.getScrollTop() + 1)
						session.setScrollTop(session.getScrollTop() - 1)

				onSessionChangeForSpellCheck = (e) ->
					spellCheckManager.onSessionChange()
					e.oldSession?.getDocument().off "change", spellCheckManager.onChange
					e.session.getDocument().on "change", spellCheckManager.onChange
					e.oldSession?.off "changeScrollTop", spellCheckManager.onScroll
					e.session.on "changeScrollTop", spellCheckManager.onScroll

				initSpellCheck = () ->
					spellCheckManager.init()
					editor.on 'changeSession', onSessionChangeForSpellCheck
					onSessionChangeForSpellCheck({ session: editor.getSession() }) # Force initial setup
					editor.on 'nativecontextmenu', spellCheckManager.onContextMenu

				tearDownSpellCheck = () ->
					editor.off 'changeSession', onSessionChangeForSpellCheck
					editor.off 'nativecontextmenu', spellCheckManager.onContextMenu

				onSessionChangeForCursorPosition = (e) ->
					e.oldSession?.selection.off 'changeCursor', cursorPositionManager.onCursorChange
					e.session.selection.on 'changeCursor', cursorPositionManager.onCursorChange

				onUnloadForCursorPosition = () ->
					cursorPositionManager.onUnload(editor.getSession())

				initCursorPosition = () ->
					editor.on 'changeSession', onSessionChangeForCursorPosition
					onSessionChangeForCursorPosition({ session: editor.getSession() }) # Force initial setup
					$(window).on "unload", onUnloadForCursorPosition

				tearDownCursorPosition = () ->
					editor.off 'changeSession', onSessionChangeForCursorPosition
					$(window).off "unload", onUnloadForCursorPosition

				initCursorPosition()

				# Trigger the event once *only* - this is called after Ace is connected
				# to the ShareJs instance but this event should only be triggered the
				# first time the editor is opened. Not every time the docs opened
				triggerEditorInitEvent = _.once () ->
					scope.$broadcast('editorInit')

				attachToAce = (sharejs_doc) ->
					lines = sharejs_doc.getSnapshot().split("\n")
					session = editor.getSession()
					if session?
						session.destroy()

					# see if we can lookup a suitable mode from ace
					# but fall back to text by default
					try
						if /\.(Rtex|bbl)$/i.test(scope.fileName)
							# recognise Rtex and bbl as latex
							mode = "ace/mode/latex"
						else if /\.(sty|cls|clo)$/.test(scope.fileName)
							# recognise some common files as tex
							mode = "ace/mode/tex"
						else
							mode = ModeList.getModeForPath(scope.fileName).mode
							# we prefer plain_text mode over text mode because ace's
							# text mode is actually for code and has unwanted
							# indenting (see wrapMethod in ace edit_session.js)
							if mode is "ace/mode/text"
								mode = "ace/mode/plain_text"
					catch
						mode = "ace/mode/plain_text"

					# create our new session
					session = new EditSession(lines, mode)

					session.setUseWrapMode(true)
					# use syntax validation only when explicitly set
					if scope.syntaxValidation? and syntaxValidationEnabled and !/\.bib$/.test(scope.fileName)
						session.setOption("useWorker", scope.syntaxValidation);

					# now attach session to editor
					editor.setReadOnly(true) # set to readonly until document change handlers are attached
					editor.setSession(session)

					doc = session.getDocument()
					doc.on "change", onChange

					editor.initing = true
					sharejs_doc.attachToAce(editor)
					editor.initing = false
					# now ready to edit document
					editor.setReadOnly(scope.readOnly) # respect the readOnly setting, normally false
					triggerEditorInitEvent()
					initSpellCheck()

					resetScrollMargins()

					# need to set annotations after attaching because attaching
					# deletes and then inserts document content
					session.setAnnotations scope.annotations


					session.on "changeScrollTop", event_tracking.editingSessionHeartbeat

					angular.element($window).on('click',
						event_tracking.editingSessionHeartbeat)

					scope.$on "$destroy", () ->
						angular.element($window).off('click',
							event_tracking.editingSessionHeartbeat)

					if scope.eventsBridge?
						session.on "changeScrollTop", onScroll

					$rootScope.hasLintingError = false
					session.on('changeAnnotation', () ->
						# Both linter errors and compile logs are set as error annotations,
						# however when the user types something, the compile logs are
						# replaced with linter errors. When we check for lint errors before
						# autocompile we are guaranteed to get linter errors
						hasErrors = session
							.getAnnotations()
							.filter((annotation) -> annotation.type != 'info')
							.length > 0

						if ($rootScope.hasLintingError != hasErrors)
							$rootScope.hasLintingError = hasErrors
					)

					setTimeout () ->
						# Let any listeners init themselves
						onScroll(editor.renderer.getScrollTop())

					editor.focus()

				detachFromAce = (sharejs_doc) ->
					tearDownSpellCheck()
					sharejs_doc.detachFromAce()
					sharejs_doc.off "remoteop.recordRemote"

					session = editor.getSession()
					session.off "changeScrollTop"

					doc = session.getDocument()
					doc.off "change", onChange

				editor.renderer.on "changeCharacterSize", () ->
					scope.$apply () ->
						scope.rendererData.lineHeight = editor.renderer.lineHeight

				scope.$watch "rendererData", (rendererData) ->
					if rendererData?
						rendererData.lineHeight = editor.renderer.lineHeight

				scope.$on '$destroy', () ->
					if scope.sharejsDoc?
						scope.$broadcast('changeEditor')
						tearDownSpellCheck()
						tearDownCursorPosition()
						detachFromAce(scope.sharejsDoc)
						session = editor.getSession()
						session?.destroy()
						scope.eventsBridge.emit "aceScrollbarVisibilityChanged", false, 0

				scope.$emit "#{scope.name}:inited", editor

			template: """
				<div class="ace-editor-wrapper">
					<div
						class="undo-conflict-warning alert alert-danger small"
						ng-show="undo.show_remote_warning"
					>
						<strong>Watch out!</strong>
						We had to undo some of your collaborators changes before we could undo yours.
						<a
							href="#"
							class="pull-right"
							ng-click="undo.show_remote_warning = false"
						>Dismiss</a>
					</div>
					<div class="ace-editor-body"></div>
					<spell-menu
						open="spellMenu.open"
						top="spellMenu.top"
						left="spellMenu.left"
						layout-from-bottom="spellMenu.layoutFromBottom"
						highlight="spellMenu.highlight"
						replace-word="replaceWord(highlight, suggestion)"
						learn-word="learnWord(highlight)"
					></spell-menu>
					<div
						class="annotation-label"
						ng-show="annotationLabel.show"
						ng-style="{
							position: 'absolute',
							left:     annotationLabel.left,
							right:    annotationLabel.right,
							bottom:   annotationLabel.bottom,
							top:      annotationLabel.top,
							'background-color': annotationLabel.backgroundColor
						}"
					>
						{{ annotationLabel.text }}
					</div>

					<a
						href
						class="highlights-before-label btn btn-info btn-xs"
						ng-show="updateLabels.highlightsBefore > 0"
						ng-click="gotoHighlightAbove()"
					>
						<i class="fa fa-fw fa-arrow-up"></i>
						{{ updateLabels.highlightsBefore }} more update{{ updateLabels.highlightsBefore > 1 && "" || "s" }} above
					</a>

					<a
						href
						class="highlights-after-label btn btn-info btn-xs"
						ng-show="updateLabels.highlightsAfter > 0"
						ng-click="gotoHighlightBelow()"
					>
						<i class="fa fa-fw fa-arrow-down"></i>
						{{ updateLabels.highlightsAfter }} more update{{ updateLabels.highlightsAfter > 1 && "" || "s" }} below

					</a>
				</div>
			"""
		}

	monkeyPatchSearch = ($rootScope, $compile) ->
		SearchBox = ace.require("ace/ext/searchbox").SearchBox
		searchHtml = """
			<div class="ace_search right">
				<a href type="button" action="hide" class="ace_searchbtn_close">
					<i class="fa fa-fw fa-times"></i>
				</a>
				<div class="ace_search_form">
					<input class="ace_search_field form-control input-sm" placeholder="Search for" spellcheck="false"></input>
					<div class="btn-group">
						<button type="button" action="findNext" class="ace_searchbtn next btn btn-default btn-sm">
							<i class="fa fa-chevron-down fa-fw"></i>
						</button>
						<button type="button" action="findPrev" class="ace_searchbtn prev btn btn-default btn-sm">
							<i class="fa fa-chevron-up fa-fw"></i>
						</button>
					</div>
				</div>
				<div class="ace_replace_form">
					<input class="ace_search_field form-control input-sm" placeholder="Replace with" spellcheck="false"></input>
					<div class="btn-group">
						<button type="button" action="replaceAndFindNext" class="ace_replacebtn btn btn-default btn-sm">Replace</button>
						<button type="button" action="replaceAll" class="ace_replacebtn btn btn-default btn-sm">All</button>
					</div>
				</div>
				<div class="ace_search_options">
					<div class="btn-group">
						<span action="toggleRegexpMode" class="btn btn-default btn-sm" tooltip-placement="bottom" tooltip-append-to-body="true" tooltip="RegExp Search">.*</span>
						<span action="toggleCaseSensitive" class="btn btn-default btn-sm" tooltip-placement="bottom" tooltip-append-to-body="true" tooltip="CaseSensitive Search">Aa</span>
						<span action="toggleWholeWords" class="btn btn-default btn-sm" tooltip-placement="bottom" tooltip-append-to-body="true" tooltip="Whole Word Search">"..."</span>
					</div>
				</div>
			</div>
		"""

		# Remove Ace CSS
		$("#ace_searchbox").remove()

		$init = SearchBox::$init
		SearchBox::$init = () ->
			@element = $compile(searchHtml)($rootScope.$new())[0];
			$init.apply(@)
