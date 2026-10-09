import {check, Match} from 'meteor/check'
import {Mongo} from 'meteor/mongo'
import {Random} from 'meteor/random'

import {validId} from './id'
import {checkRoom} from './rooms'
import {defaultGridType, validGridType} from './grid'
import {planOrderRestore, planRestore} from './pageOrder'

@Pages = new Mongo.Collection 'pages'

## How often `pagesRestore` plans again when the room's pages keep changing
restoreAttempts = 10

export checkPage = (page) ->
  if validId(page) and data = Pages.findOne page
    data
  else
    throw new Meteor.Error "Invalid page ID #{page}"

Meteor.methods
  pageNew: (page, index) ->
    check page,
      room: String
      grid: Match.Optional Boolean
      gridType: Match.Optional Match.Where validGridType
    check index, Match.Optional Number
    unless @isSimulation
      now = new Date
      page.created = now
    roomId = page.room
    room = checkRoom roomId
    pageId = Pages.insert page, channel: "rooms::#{roomId}::pages"
    Rooms.update roomId,
      $push: pages:
        $each: [pageId]
        $position: index ? room?.pages?.length ? 0
    pageId

  pageDup: (pageId) ->
    check pageId, String
    page = checkPage pageId
    room = checkRoom page.room
    index = room.pages?.indexOf pageId
    unless index? and index >= 0
      throw new Meteor.Error "Page #{page._id} not found in its room #{room._id}"
    delete page._id
    delete page.created
    ## Not part of a new page: markers of deleting and restoring pages
    delete page.deleted
    delete page.restored
    newPageId = Meteor.apply 'pageNew', [page, index+1]
    Objects.find
      room: room._id
      page: pageId
    .forEach (obj) ->
      delete obj._id
      delete obj.created
      delete obj.updated
      obj.page = newPageId
      Meteor.call 'objectNew', obj
    newPageId

  ## Deleting pages never removes any data: the pages just leave the room's
  ## page list and get marked `deleted` (an `id` of this deletion, when, by
  ## whom, and which page came before), so that `pagesRestore` can put them
  ## back where they were.
  ## Returns the time of deletion (in milliseconds) from the server.
  pagesDel: (pageIds, remoteId) ->
    check pageIds, [String]
    check remoteId, Match.Optional String
    pageIds = Array.from new Set pageIds
    throw new Meteor.Error "No pages to delete" unless pageIds.length
    room = checkRoom checkPage(pageIds[0]).room
    for pageId in pageIds
      unless checkPage(pageId).room == room._id
        throw new Meteor.Error "Page #{pageId} is not in room #{room._id}"
    ## Pages that are already deleted (e.g. by someone else at the same time)
    ## stay deleted.
    pages = room.pages ? []
    pageIds = (pageId for pageId in pageIds when pageId in pages)
    return unless pageIds.length
    if pages.every((pageId) -> pageId in pageIds)
      throw new Meteor.Error "Cannot delete every page in a room"
    ## Remove pages from the room first, so that clients stop showing them.
    ## The `$elemMatch` condition makes the check above atomic, in case two
    ## users delete pages at the same time.
    selector = _id: room._id
    selector.pages = $elemMatch: $nin: pageIds unless @isSimulation
    updated = Rooms.update selector,
      $pullAll: pages: pageIds
    unless updated or @isSimulation
      throw new Meteor.Error "Cannot delete every page in a room"
    at = new Date unless @isSimulation
    ## `id` tells the markers of this deletion from those of any other deletion
    ## of the same pages, even one made at the very same moment.  Each page is
    ## marked after being removed, so that no overlapping `pagesRestore` (which
    ## clears only the marker it started from) can leave it without a marker.
    id = Random.id()
    for pageId in pageIds
      deleted = {id, prev: pages[pages.indexOf(pageId) - 1] ? null}
      deleted.by = remoteId if remoteId?
      deleted.at = at if at?
      Pages.update pageId,
        $set: {deleted}
      , channel: "rooms::#{room._id}::pages"
    ## Cursors on deleted pages are not worth keeping.
    unless @isSimulation
      Remotes.remove
        room: room._id
        page: $in: pageIds
      , channel: "rooms::#{room._id}::remotes"
    at?.getTime()

  ## Put deleted pages back in the room's page list and give them a `restored`
  ## marker (`token`) so that each browser can show them zoomed to fit the first
  ## time it opens them.  Pages that are not deleted are ignored, and no page
  ## is ever removed.  Returns the restored page IDs.
  ## With `order` (the room's page list from right before the deletion that is
  ## being undone), pages go back next to the pages that were their neighbors
  ## then; otherwise, next to the page that came before each one when it was
  ## deleted (see `planOrderRestore` and `planRestore`).
  pagesRestore: (pageIds, token, order) ->
    check pageIds, [String]
    check token, Match.Optional Number
    check order, Match.Optional [String]
    pageIds = Array.from new Set pageIds
    throw new Meteor.Error "No pages to restore" unless pageIds.length
    roomId = checkPage(pageIds[0]).room
    for pageId in pageIds
      unless checkPage(pageId).room == roomId
        throw new Meteor.Error "Page #{pageId} is not in room #{roomId}"
    prevOf = (pageId) -> Pages.findOne(pageId)?.deleted?.prev
    ## The new page list is written in a single update, which applies only if
    ## the room's page list is still the one the plan was made from.  If
    ## someone changed it in between (adding, deleting, or restoring pages),
    ## plan again from the new list, so that the pages never land in the wrong
    ## places.
    missing = deletedIds = null
    for attempt in [1..restoreAttempts]
      room = checkRoom roomId
      pages = room.pages ? []
      missing = (pageId for pageId in pageIds when pageId not in pages)
      return [] unless missing.length
      ## Which deletion each page is being restored from
      deletedIds = {}
      deletedIds[pageId] = Pages.findOne(pageId)?.deleted?.id for pageId in missing
      {pages: newPages} =
        if order?
          planOrderRestore pages, order, missing
        else
          planRestore pages, missing, prevOf
      if @isSimulation
        Rooms.update roomId, $set: pages: newPages
        break
      selector = _id: roomId
      selector.pages = if room.pages? then pages else $exists: false
      break if Rooms.update selector, $set: pages: newPages
      if attempt == restoreAttempts
        throw new Meteor.Error "The pages of room #{roomId} keep changing"
    ## Clear the deletion marker, but only the one these pages were restored
    ## from (the one seen when planning, or none): if someone deleted one of
    ## them again meanwhile, its new marker must stay, so that others are still
    ## offered to bring it back.
    for pageId in missing
      selector = _id: pageId
      unless @isSimulation
        selector['deleted.id'] = deletedIds[pageId] ? $exists: false
      modifier = $unset: deleted: ''
      modifier.$set = restored: token if token?
      Pages.update selector, modifier, channel: "rooms::#{roomId}::pages"
    missing

  gridToggle: (page, gridType) ->
    check page, String
    check gridType, Match.Optional Match.Where validGridType
    data = checkPage page
    existingType = data.gridType ? defaultGridType
    set =
      grid:
        if data.grid and (not gridType? or existingType == gridType)
          false
        else
          true
    set.gridType = gridType if gridType?
    Pages.update page,
      $set: set
    , channel: "rooms::#{data.room}::pages"
