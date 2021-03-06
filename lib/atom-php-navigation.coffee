AtomPhpNavigationView = require './atom-php-navigation-view'
{CompositeDisposable, Range} = require 'atom'
$ = require 'jquery'
fs = require 'fs'
trim = require 'trim'
scandir = require('scandir').create()
_markers = {};
_tree = {};
_ready2click = true;#false;
_disposebls = [];

module.exports = AtomPhpNavigation =
  atomPhpNavigationView: null
  modalPanel: null
  subscriptions: null
  enabled: false
  indexingRunned: false
  extendsRegExp: /^[\t\n\s]?(class|interface|trait|abstract class)\s([\S]+?)\s(\s?extends ([\w\d\_\\]+))?(\s?implements ([\w\d\_\\,\n\s]+))?/g
  useRegExp: /use\s([\w\d_\\]+)[\s\w\d]?;/g
  classRegExp: /^[\t\n\s]?(interface|abstract class|class) ([\d\w_\\]+)(|\n)/
  namespaceRegExp: /namespace (.*?);/
  classCallRegExp: /([\s\t\(\r\n]+|=)(new ([\w\d\\_]+)|([\w\d\\_]+)(::|\s+\$))/g

  getTree: ->
    return _tree;

  printTree: ->
    console.log @getTree();

  activate: (state) ->
    @atomPhpNavigationView = new AtomPhpNavigationView(state.atomPhpNavigationViewState)
    @modalPanel = atom.workspace.addModalPanel(item: @atomPhpNavigationView.getElement(), visible: false)

    # Events subscribed to in atom's system can be easily cleaned up with a CompositeDisposable
    @subscriptions = new CompositeDisposable

    # Register command that toggles this view
    @subscriptions.add atom.commands.add 'atom-workspace', 'atom-php-navigation:toggle': => @toggle()

  deactivate: ->
    @modalPanel.destroy()
    @subscriptions.dispose()
    @atomPhpNavigationView.destroy()

  serialize: ->
    atomPhpNavigationViewState: @atomPhpNavigationView.serialize()

  toggle: ->
    @indexing()

    if @enabled
      @disable()
    else
      @enable()

  toggleKey: (e) ->
    _ready2click = e.altKey != e.metaKey

  enable: ->
    @enabled = true
    console.log 'On'

    @editorViewSubscription = atom.workspace.observeTextEditors (editor) =>
      editorView = atom.views.getView(editor)
      editorView.addEventListener 'keydown', @toggleKey
      editorView.addEventListener 'keyup', @toggleKey

      @scanExtends(editor)
      @scanUses(editor)
      @scanCallClasses(editor)

  disable: ->
    @enabled = false
    console.log 'Off'

    @_stopIndexation()
    @editorViewSubscription = atom.workspace.observeTextEditors (editor) =>
      editorView = atom.views.getView(editor)
      editorView.removeEventListener 'keydown', @toggleKey
      editorView.removeEventListener 'keyup', @toggleKey

      editor.getMarkers().map (marker) ->
        if marker.getProperties().className != undefined
          marker.destroy()

    _disposebls.map (dip) ->
      dip.dispose()

  createMarker: (editor, res, match, fromStart = false, startCb = null) ->
    match = trim match
    namespace = match.split "\\"
    className = namespace[namespace.length - 1]
    row = res.computedRange.end.row
    if typeof startCb != 'function'
      startCb = () ->
        return res.match[0].indexOf(' ' + match)

    start_c = if res.computedRange.start.row < res.computedRange.end.row then 0 else res.computedRange.start.column
    start = if fromStart then start_c else startCb() + 1
    end = start + match.length
    range = new Range([row, start], [row, end])
    marker = editor.markBufferRange(range)
    markerProperties =
      className: className
      namespace: if namespace[0] == '\\' then namespace.slice(1, namespace.length).join '\\' else namespace.join '\\'

    marker.setProperties markerProperties

    options =
      type: 'line'
      class: 'clickable-class'

    editor.decorateMarker marker, options
    return marker

  scanCallClasses: (editor) ->
    self = @
    # Find used classes and traits in opened files
    editor.scan @classCallRegExp, (res) ->
      if res.match.length < 4
        return false

      markers = []
      if res.match[3] != undefined
        markers.push(self.createMarker(editor, res, res.match[3], true))

      if res.match[4] != undefined
        markers.push(self.createMarker(editor, res, res.match[4], true))

      _disposebls.push(
        editor.onDidChangeCursorPosition (event) ->
          markers.map((marker) ->
            if marker.getBufferRange().containsPoint(event.newBufferPosition)
              props = marker.getProperties()
              className = props.className
              self.openClassFile className, res.filePath, props.namespace
          )
      )

  scanUses: (editor) ->
    self = @
    # Find used classes and traits in opened files
    editor.scan @useRegExp, (res) ->
      if res.match.length < 2
        return false

      marker = self.createMarker(editor, res, res.match[1])
      _disposebls.push(
        editor.onDidChangeCursorPosition (event) ->
          if marker.getBufferRange().containsPoint(event.newBufferPosition)
            props = marker.getProperties()
            className = props.className
            self.openClassFile className, res.filePath, props.namespace
      )

  scanExtends: (editor) ->
    self = @
    # Find classes and parent classes in opened files
    editor.scan @extendsRegExp, (res) ->
      if res.match.length < 5
        return false

      markers = []
      if res.match[4] != undefined
        match = trim res.match[4]
        add = trim(res.match[3].split(' ')[0]) + ' ';
        startCb = () ->
          return res.match[0].indexOf(add + match) + add.length

        markers.push(self.createMarker(editor, res, match, false, startCb))

      if res.match[6] != undefined
        res.match[6].split(',').map((str) ->
          str = trim str

          startCb = () ->
            _s = res.match[5].indexOf ' ' + str
            return res.match[0].indexOf(res.match[5]) + _s

          markers.push(self.createMarker(editor, res, str, false, startCb))
        )

      _disposebls.push(
        editor.onDidChangeCursorPosition (event) ->
          markers.map((marker) ->
            if marker.getBufferRange().containsPoint(event.newBufferPosition)
              props = marker.getProperties()
              className = props.className
              self.openClassFile className, res.filePath, props.namespace
          )
      )

  openClassFile: (className, path, namespace) ->
    if _ready2click == false
      return false

    if _tree[className] != undefined and typeof _tree[className][0] == 'object'
      atom.open {pathsToOpen: _tree[className][0].path}
    else
      exp = new RegExp "^(class|interface|trait|abstract class) (" + className + ")[^\\w\\d]+"
      atom.workspace.scan exp, (res) ->
        if res.filePath
          atom.open {pathsToOpen: res.filePath}
          _tree[className] =
            path: path
            className: className
            namespace: namespace

  indexing: ->
    if !@indexingRunned
      @indexingRunned = true
      @modalPanel.show()
    else
      return false

    self = @

    path = atom.project.getPaths()[0]
    scandir.on 'file', (filePath, stats) ->
      fs.readFile filePath, encoding: 'utf-8', (err, data) ->
        dataArr = data.split /\n/g
        dataArr.forEach((line, n) ->
          namespace = line.match self.namespaceRegExp
          className = line.match self.classRegExp

          if !className
            return false

          className = if className then className[2] else null
          fileName = filePath.split('/')
          fileName = fileName[fileName.length - 1]

          key = if className then className else fileName
          if _tree[key] == undefined
            _tree[key] = []

          _tree[key].push
            line: n + 1,
            namespace: if namespace then namespace[1] else ''
            className: className
            path: filePath
        )

      return

    scandir.on 'error', (err) ->
      console.error err
      return

    self = @
    scandir.on 'end', ->
      if self.indexingRunned
        self.indexingComplete()
      return

    scandir.scan
      dir: path
      recursive: true
      filter: /\.php/

  _stopIndexation: () ->
    @indexingRunned = false
    if @modalPanel.isVisible()
      @modalPanel.hide()

  indexingComplete: ->
    @_stopIndexation()
    @printTree()
