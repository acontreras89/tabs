path = require 'path'
{$} = require 'atom-space-pen-views'
{CompositeDisposable} = require 'atom'

module.exports =
class TabView extends HTMLElement
  initialize: (@item) ->
    @path = @item.getPath?()

    @repoSubscriptions = new CompositeDisposable()

    @isPreviewTab = atom.config.get('tabs.usePreviewTabs') and typeof @item.getPath is 'function'

    @classList.add('tab', 'sortable')

    @itemTitle = document.createElement('div')
    @itemTitle.classList.add('title')
    @appendChild(@itemTitle)

    closeIcon = document.createElement('div')
    closeIcon.classList.add('close-icon')
    @appendChild(closeIcon)

    @handleEvents()
    @updateDataAttributes()
    @updateTitle()
    @updateIcon()
    @updateModifiedStatus()
    @setupTooltip()
    @setupVcsStatus()

    if @isPreviewTab
      @itemTitle.classList.add('temp')
      @classList.add('preview-tab')
      @addEventListener 'dblclick', => @clearPreview()

  handleEvents: ->
    titleChangedHandler = =>
      @updateDataAttributes()
      @updateTitle()
      @updateTooltip()

    if typeof @item.onDidChangeTitle is 'function'
      @titleSubscription = @item.onDidChangeTitle(titleChangedHandler)
    else if typeof @item.on is 'function'
      #TODO Remove once old events are no longer supported
      @item.on('title-changed', titleChangedHandler)
      @titleSubscription = dispose: =>
        @item.off?('title-changed', titleChangedHandler)

    iconChangedHandler = =>
      @updateIcon()

    if typeof @item.onDidChangeIcon is 'function'
      @iconSubscription = @item.onDidChangeIcon? =>
        @updateIcon()
    else if typeof @item.on is 'function'
      #TODO Remove once old events are no longer supported
      @item.on('icon-changed', iconChangedHandler)
      @iconSubscription = dispose: =>
        @item.off?('icon-changed', iconChangedHandler)

    modifiedHandler = =>
      @updateModifiedStatus()

    if typeof @item.onDidChangeModified is 'function'
      @modifiedSubscription = @item.onDidChangeModified(modifiedHandler)
    else if typeof @item.on is 'function'
      #TODO Remove once old events are no longer supported
      @item.on('modified-status-changed', modifiedHandler)
      @modifiedSubscription = dispose: =>
        @item.off?('modified-status-changed', modifiedHandler)

    itemSavedHandler = (event) =>
      if @path isnt event.path
        @path = event.path
        @setupVcsStatus()

    @savedSubscription = @item.buffer?.onDidSave(itemSavedHandler)

    @configSubscription = atom.config.observe 'tabs.showIcons', =>
      @updateIconVisibility()

    @vcsConfigSubscription = atom.config.observe 'tabs.enableVcsColoring', =>
      @updateVcsColoring()

  setupTooltip: ->
    # Defer creating the tooltip until the tab is moused over
    onMouseEnter = =>
      @mouseEnterSubscription.dispose()
      @hasBeenMousedOver = true
      @updateTooltip()

      # Trigger again so the tooltip shows
      @dispatchEvent(new CustomEvent('mouseenter', bubbles: true))

    @mouseEnterSubscription = dispose: =>
      @removeEventListener('mouseenter', onMouseEnter)
      @mouseEnterSubscription = null

    @addEventListener('mouseenter', onMouseEnter)

  updateTooltip: ->
    return unless @hasBeenMousedOver

    @destroyTooltip()

    if @path
      @tooltip = atom.tooltips.add this,
        title: @path
        html: false
        delay:
          show: 1000
          hide: 100
        placement: 'bottom'

  destroyTooltip: ->
    return unless @hasBeenMousedOver
    @tooltip?.dispose()

  destroy: ->
    @titleSubscription?.dispose()
    @modifiedSubscription?.dispose()
    @iconSubscription?.dispose()
    @mouseEnterSubscription?.dispose()
    @configSubscription?.dispose()
    @vcsConfigSubscription?.dispose()
    @savedSubscription?.dispose()
    @repoSubscriptions?.dispose()
    @destroyTooltip()
    @remove()

  updateDataAttributes: ->
    if @path
      @itemTitle.dataset.name = path.basename(@path)
      @itemTitle.dataset.path = @path
    else
      delete @itemTitle.dataset.name
      delete @itemTitle.dataset.path

    if itemClass = @item.constructor?.name
      @dataset.type = itemClass
    else
      delete @dataset.type

  updateTitle: ({updateSiblings, useLongTitle}={}) ->
    return if @updatingTitle
    @updatingTitle = true

    if updateSiblings is false
      title = @item.getTitle()
      title = @item.getLongTitle?() ? title if useLongTitle
      @itemTitle.textContent = title
    else
      title = @item.getTitle()
      useLongTitle = false
      for tab in @getTabs() when tab isnt this
        if tab.item.getTitle() is title
          tab.updateTitle(updateSiblings: false, useLongTitle: true)
          useLongTitle = true
      title = @item.getLongTitle?() ? title if useLongTitle

      @itemTitle.textContent = title

    @updatingTitle = false

  updateIcon: ->
    if @iconName
      @itemTitle.classList.remove('icon', "icon-#{@iconName}")

    if @iconName = @item.getIconName?()
      @itemTitle.classList.add('icon', "icon-#{@iconName}")

  getTabs: ->
    @parentElement?.querySelectorAll('.tab') ? []

  clearPreview: ->
    @isPreviewTab = false
    @itemTitle.classList.remove('temp')
    @classList.remove('preview-tab')

  updateIconVisibility: ->
    if atom.config.get 'tabs.showIcons'
      @itemTitle.classList.remove('hide-icon')
    else
      @itemTitle.classList.add('hide-icon')

  updateModifiedStatus: ->
    if @item.isModified?()
      @clearPreview()
      @classList.add('modified') unless @isModified
      @isModified = true
    else
      @classList.remove('modified') if @isModified
      @isModified = false

  setupVcsStatus: ->
    return unless @path?
    @repoForPath().then (repo) =>
      if repo?
        @subscribeToRepo(repo)
        @updateVcsStatus(repo)
    .catch (error) =>
      # TODO: Handle error. We can get here for two reasons:
      # Either repo has been destroyed by the time the promise is resolved, or
      # the repo provider's repositoryForDirectory function thrown an error

  # Subscribe to the project's repo for changes to the VCS status of the file.
  subscribeToRepo: (repo) ->
    return unless repo?

    # Remove previous repo subscriptions.
    @repoSubscriptions?.dispose()

    @repoSubscriptions.add repo.onDidChangeStatus (event) =>
      @updateVcsStatus(repo, event.pathStatus) if event.path is @path
    @repoSubscriptions.add repo.onDidChangeStatuses =>
      @updateVcsStatus(repo)

  repoForPath: ->
    for dir in atom.project.getDirectories()
      if dir.contains @path
        return atom.project.repositoryForDirectory(dir)
    Promise.resolve null

  # Update the VCS status property of this tab using the repo.
  updateVcsStatus: (repo, status) ->
    return unless repo?

    newStatus = null
    if repo.isPathIgnored(@path)
      newStatus = 'ignored'
    else
      status = repo.getCachedPathStatus(@path) unless status?
      if repo.isStatusModified(status)
        newStatus = 'modified'
      else if repo.isStatusNew(status)
        newStatus = 'added'

    if newStatus isnt @status
      @status = newStatus
      @updateVcsColoring()

  updateVcsColoring: ->
    @itemTitle.classList.remove('status-ignored', 'status-modified',  'status-added')
    if @status and atom.config.get 'tabs.enableVcsColoring'
      @itemTitle.classList.add("status-#{@status}")

module.exports = document.registerElement('tabs-tab', prototype: TabView.prototype, extends: 'li')
