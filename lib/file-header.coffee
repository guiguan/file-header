# @Author: Guan Gui <guiguan>
# @Date:   2016-01-21T02:00:17+11:00
# @Email:  root@guiguan.net
# @Last modified by:   guiguan
# @Last modified time: 2016-01-21T22:01:06+11:00


{CompositeDisposable} = require 'atom'
fs = require 'fs'
path = require 'path'
moment = require 'moment'

module.exports = FileHeader =
  config:
    realname:
      title: 'Real Name'
      order: 1
      description: 'Your last and first name. Leave empty to disable.'
      type: 'string'
      default: ''
    username:
      title: 'Username'
      order: 2
      description: 'Your username. Only allow chars from [A-Za-z0-9_]. Leave empty to disable.' + if process.env.USER then " Your current system username is <code>#{ process.env.USER }</code>." else ''
      type: 'string'
      default: ''
    email:
      title: 'Email Address'
      order: 4
      description: 'Your email address. Leave empty to disable.'
      type: 'string'
      default: ''
    configDirPath:
      title: 'Config Directory Path'
      order: 5
      description: 'Path to the directory that contains your customized File Header <code>lang-mapping.json</code> and <code>templates</code> directory. They will override default ones came with this package.'
      type: 'string'
      default: path.join(atom.config.configDirPath, 'file-header')
    autoUpdateEnabled:
      title: 'Enable Auto Update'
      order: 6
      description: 'Auto update file header on saving. Otherwise, you can bind your own key to <code>file-header:update</code> for manually triggering update.'
      type: 'boolean'
      default: true

  subscriptions: null
  LAST_MODIFIED_BY: '{{last_modified_by}}'
  LAST_MODIFIED_TIME: '{{last_modified_time}}'
  LANG_MAPPING: 'lang-mapping.json'
  TEMPLATES: 'templates'

  activate: (state) ->
    if !state.notFirstTime
      @state = state
      @state.notFirstTime = true
      # if it is the first time this plugin is installed, we try to setup username
      # for the user
      atom.config.set('file-header.username', process.env.USER ? '')

    # Events subscribed to in atom's system can be easily cleaned up
    # with a CompositeDisposable
    @subscriptions = new CompositeDisposable

    @subscriptions.add atom.config.onDidChange 'file-header.username', (event) =>
      if !event.newValue.match(/^\w*$/)
        # The timer is used to solve a problem that due to frequent updating,
        # sometimes the username shown in the config UI is not reverted to its
        # default value, though its underlying value is
        if !@usernameDidChangeTimer
          clearTimeout(@usernameDidChangeTimer)
          @usernameDidChangeTimer = null
        @usernameDidChangeTimer = setTimeout(() =>
          atom.config.unset('file-header.username')
          atom.notifications.addError 'Invalid username', {detail: 'Please make sure it only contains characters from [A-Za-z0-9_]'}
        , 100)

    @subscriptions.add atom.config.observe 'file-header.autoUpdateEnabled', =>
      @updateToggleAutoUpdateEnabledStatusMenuItem()

    atom.workspace.observeTextEditors (editor) =>
      editor.getBuffer().onWillSave =>
        return unless atom.config.get 'file-header.autoUpdateEnabled'
        @update()

    @subscriptions.add atom.commands.add 'atom-workspace',
      'file-header:add': => @add()
      'file-header:toggleAutoUpdateEnabledStatus': => @toggleAutoUpdateEnabledStatus()
      'file-header:update': => @update()

  serialize: ->
    @state

  deactivate: ->
    @subscriptions.dispose()

  getHeaderTemplate: (editor) ->
    configDirPath = atom.config.get('file-header.configDirPath')
    currScope = editor.getRootScopeDescriptor().getScopesArray()[0]
    templateFileName = null
    try
      # lookup user defined lang-mapping
      langMapping = JSON.parse(fs.readFileSync(path.join(configDirPath, @LANG_MAPPING), encoding: "utf8"))
      templateFileName = langMapping[currScope]
    if !templateFileName
      # fallback to default lang-mapping
      langMapping = JSON.parse(fs.readFileSync(path.join(__dirname, @LANG_MAPPING), encoding: "utf8"))
      templateFileName = langMapping[currScope]
    if !templateFileName
      return
    template = null
    try
      # lookup user defined template
      template = fs.readFileSync(path.join(configDirPath, @TEMPLATES, templateFileName), encoding: "utf8")
    if !template
      template = fs.readFileSync(path.join(__dirname, @TEMPLATES, templateFileName), encoding: "utf8")
    template

  getNewHeader: (headerTemplate) ->
    return null unless headerTemplate
    realname = atom.config.get 'file-header.realname'
    username = atom.config.get 'file-header.username'
    email = atom.config.get 'file-header.email'
    if realname
      author = realname
      if username
        author += " <#{ username }>"
    else
      author = username
    byName = if username then username else realname

    if author
      # fill placeholder {{author}}
      headerTemplate = headerTemplate.replace(/\{\{author\}\}/g, author)
    # fill placeholder {{create_time}} and {{last_modified_time}}
    headerTemplate = headerTemplate.replace(new RegExp("#{ @escapeRegExp('{{create_time}}') }|#{ @escapeRegExp(@LAST_MODIFIED_TIME) }", 'g'), moment().format())
    if email
      # fill placeholder {{email}}
      headerTemplate = headerTemplate.replace(/\{\{email\}\}/g, email)
    if byName
      # fill placeholder {{last_modified_by}}
      headerTemplate = headerTemplate.replace(new RegExp(@escapeRegExp(@LAST_MODIFIED_BY), 'g'), byName)
    # remove header lines with empty placeholders
    return headerTemplate = headerTemplate.replace(/^.*\{\{\w+\}\}(?:\r\n|\r|\n)/gm, '')

  escapeRegExp: (str) ->
    str.replace(/[\-\[\]\/\{\}\(\)\*\+\?\.\\\^\$\|]/g, "\\$&")

  # We consider a source file to have a file header if any placeholder line in
  # the corresponding header template is presented
  hasHeader: (buffer, headerTemplate) ->
    # these placeholder preambles are used as anchor points in source code scanning
    if !(preambles = headerTemplate.match(/@[^:]+:/g))
      return false
    re = new RegExp(preambles.join('|'), 'g')
    hasMatch = false
    buffer.scan(re, (result) =>
      hasMatch = true
      result.stop()
    )
    hasMatch

  updateField: (placeholder, headerTemplate, buffer, newValue) ->
    escaptedPlaceholder = @escapeRegExp(placeholder)
    re = new RegExp(".*(@[^:]+:).*#{ escaptedPlaceholder }.*(?:\r\n|\r|\n)", 'g')
    # find anchor point and line in current template
    while match = re.exec(headerTemplate)
      anchor = match[1]
      newLine = match[0]
      # inject new value
      newLine = newLine.replace(new RegExp(escaptedPlaceholder, 'g'), newValue)
      # find and replace line in current buffer
      reB = new RegExp(".*#{ @escapeRegExp(anchor) }.*(?:\r\n|\r|\n)", 'g')
      buffer.scan(reB, (result) =>
        result.replace(newLine)
      )

  update: ->
    return unless editor = atom.workspace.getActiveTextEditor()
    buffer = editor.getBuffer()
    return unless headerTemplate = @getHeaderTemplate editor

    # update {{last_modified_by}}
    realname = atom.config.get 'file-header.realname'
    username = atom.config.get 'file-header.username'
    byName = if username then username else realname
    @updateField @LAST_MODIFIED_BY, headerTemplate, buffer, byName

    # update {{last_modified_time}}
    @updateField @LAST_MODIFIED_TIME, headerTemplate, buffer, moment().format()

  add: ->
    return unless editor = atom.workspace.getActiveTextEditor()
    buffer = editor.getBuffer()
    return unless headerTemplate = @getHeaderTemplate editor
    return unless newHeader = @getNewHeader headerTemplate
    buffer.insert([0, 0], newHeader, normalizeLineEndings: true) unless @hasHeader(buffer, headerTemplate)

  updateToggleAutoUpdateEnabledStatusMenuItem: ->
    packages = null
    for item in atom.menu.template
      if item.label is 'Packages'
        packages = item
        break
    return unless packages
    fileHeader = null
    for item in packages.submenu
     if item.label is 'File Header'
       fileHeader = item
       break
    return unless fileHeader
    toggle = null
    for item in fileHeader.submenu
      if item.command is 'file-header:toggleAutoUpdateEnabledStatus'
        toggle = item
        break
    return unless toggle
    toggle.label = if atom.config.get 'file-header.autoUpdateEnabled' then 'Disable Auto Update' else 'Enable Auto Update'
    atom.menu.update()

  toggleAutoUpdateEnabledStatus: ->
    atom.config.set('file-header.autoUpdateEnabled', !atom.config.get('file-header.autoUpdateEnabled'))
    @updateToggleAutoUpdateEnabledStatusMenuItem()
