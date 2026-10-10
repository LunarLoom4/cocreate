import {check, Match} from 'meteor/check'
import {Mongo} from 'meteor/mongo'
import {Random} from 'meteor/random'

import {validId} from './id'
import {checkRoom} from './rooms'
import {defaultGridType, validGridType} from './grid'
import {deletionKinds, historyLimit, topOf} from './pageHistory'
import {planOrderRestore} from './pageOrder'

@Pages = new Mongo.Collection 'pages'

###
Deleting pages is reversible, and the history of deleting is the same for
everyone in a room.  The rules, which everything below follows:

* A room document holds its list of `pages`, two stacks of deletion IDs, and
  two more fields.  `undo` is the deletions that can be undone, the latest at
  the end.  `redo` is the deletions that were undone, the one undone last at
  the end.  Each stack keeps at most `historyLimit` deletions.  `latest` is the
  ID of the latest deletion made, and `rev` counts changes of the stacks.
* Each deletion is one document of `PageDeletions` (see ./pageHistory) that
  never changes once the room refers to it.  It is written first, and the
  room's stacks refer to it in the same write that changes the pages.
* Deleting pages, undoing a deletion, and redoing a deletion each change the
  room's pages and its stacks in one single update, which applies only if the
  room's pages and `rev` are still what they were when the change was planned.
  So the changes of a room happen one after another, in an order that every
  reader sees, and a change that finds the room different plans again.
  Nothing can be half done, and nothing needs to be repaired.
* Deleting pages puts a deletion at the end of `undo` and empties `redo`.
  Undoing takes the deletion at the end of `undo` and puts it at the end of
  `redo`; it only ever brings pages back.  Redoing takes the deletion at the
  end of `redo`, deletes its pages that are in the room, and puts the result
  as a new deletion at the end of `undo`.
* Undoing or redoing names the deletion it is for.  If that deletion is not the
  one at the end of its stack when the update happens (someone else changed
  the history after the person looked at it), nothing happens.
* Deleting every page of a room adds one blank page, in the same update.  The
  caller says what ID the page gets, so that the page it shows at once is the
  page that is saved.
###

@PageDeletions = new Mongo.Collection 'pageDeletions'

## Every change to `PageDeletions` of a room is on this channel
deletionsChannel = (roomId) -> "rooms::#{roomId}::pageDeletions"
pagesChannel = (roomId) -> "rooms::#{roomId}::pages"

## How often a change plans again when the room keeps changing.  Each time it
## plans again, some other change has succeeded, so this is only a limit for a
## runaway loop.
planAttempts = 1000

export checkPage = (page) ->
  if validId(page) and data = Pages.findOne page
    data
  else
    throw new Meteor.Error "Invalid page ID #{page}"

## Matches the room only while its pages and history are what `room` (a copy of
## it that a change was planned from) says.
unchanged = (room) ->
  selector = _id: room._id
  selector.pages = if room.pages? then room.pages else $exists: false
  selector.rev = if room.rev? then room.rev else $exists: false
  selector

## Forget deletions that the room's stacks no longer refer to.  (This only
## forgets how to undo and redo them: the pages and everything on them stay in
## the database.)  If this fails, they are just left unused.
forgetDeletions = (roomId, ids) ->
  return unless ids.length
  try
    PageDeletions.remove {_id: {$in: ids}, room: roomId},
      channel: deletionsChannel roomId
  catch error
    console.error "Could not forget deletions #{ids} of room #{roomId}: #{error}"
  return

## The document of a new blank page: `blank` is what the caller sent (the ID the
## page gets, and whether it has a grid and which kind), `fields` is the rest.
## The ID is the caller's, not made here, so that the page that the caller shows
## right away is the page that gets saved.
blankPage = (roomId, blank, fields) ->
  page = Object.assign {_id: blank.id, room: roomId}, fields
  page.grid = blank.grid if blank.grid?
  page.gridType = blank.gridType if blank.gridType?
  page

## Make the one update of a change to the room.  Returns whether it applied
## (it does not if someone changed the room first).  If the update fails with an
## error, it may have been applied just before the error: the room shows it, by
## `shows(room)`, if so.  If the room cannot be looked at to find out, the error
## has `unsure` set, and what the change refers to must be left alone.
updateRoom = (roomId, selector, changes, shows) ->
  try
    Rooms.update(selector, changes) > 0
  catch error
    try
      current = checkRoom roomId
    catch
      error.unsure = true
      throw error
    throw error unless shows current
    true

## Delete pages from a room, either the `requested` ones or, for redoing the
## deletion `redoOf`, the pages of that deletion that are in the room.  This is
## the one update described at the top.  `recordId` is the ID the new deletion
## gets, and `blank` is what the new blank page (if the room needs one) is made
## from, with its ID.  Returns the ID of the blank page if one was added.
deleteStep = (roomId, requested, remoteId, kind, redoOf, blank, recordId) ->
  at = new Date
  wroteRecord = wroteBlank = committed = unsure = false
  try
    for [1..planAttempts]
      room = checkRoom roomId
      pages = room.pages ? []
      undo = room.undo ? []
      redo = room.redo ? []
      wanted = requested
      if redoOf?
        ## Only the deletion undone last can be redone
        return unless topOf(redo) == redoOf
        redone = PageDeletions.findOne redoOf
        return unless redone?.room == roomId
        wanted = redone.ids
        kind = redone.kind
      ## Pages that are not in the room (e.g. already deleted by someone else at
      ## the same time) are left out.
      wanted = new Set wanted
      pageIds = (pageId for pageId in pages when wanted.has pageId)
      return unless pageIds.length
      addBlank = pageIds.length == pages.length
      if addBlank and not blank?
        throw new Meteor.Error "Cannot delete every page in a room"
      deleting = new Set pageIds
      newPages =
        if addBlank
          [blank.id]
        else
          (pageId for pageId in pages when not deleting.has pageId)
      ## The deletion first, then the room refers to it.  A blank page also
      ## first exists, and then the room refers to it.
      record =
        room: roomId
        kind: kind ? 'current'
        ids: pageIds
        order: if addBlank then pages.concat [blank.id] else pages
        at: at
      record.by = remoteId if remoteId?
      if wroteRecord
        PageDeletions.update recordId, {$set: record},
          channel: deletionsChannel roomId
      else
        PageDeletions.insert Object.assign({_id: recordId}, record),
          channel: deletionsChannel roomId
        wroteRecord = true
      if addBlank and not wroteBlank
        Pages.insert blankPage(roomId, blank, created: at),
          channel: pagesChannel roomId
        wroteBlank = true
      else if wroteBlank and not addBlank
        Pages.remove blank.id, channel: pagesChannel roomId
        wroteBlank = false
      changes =
        $set: {pages: newPages, latest: recordId}
        $inc: {rev: 1}
        $push: {undo: {$each: [recordId], $slice: -historyLimit}}
      if redoOf?
        changes.$pop = {redo: 1}
      else
        changes.$set.redo = []  # a new deletion ends what could be redone
      try
        committed = updateRoom roomId, unchanged(room), changes, (current) ->
          recordId in (current.undo ? []) or recordId in (current.redo ? [])
      catch error
        unsure = true if error.unsure
        throw error
      break if committed
      ## Someone changed the room's pages or history in between: plan again.
    unless committed
      throw new Meteor.Error "The pages of room #{roomId} keep changing"
  finally
    ## Nothing was deleted: the deletion and the page were never used
    unless committed or unsure
      if wroteRecord
        forgetDeletions roomId, [recordId]
      if wroteBlank
        try
          Pages.remove blank.id, channel: pagesChannel roomId
        catch error
          console.error "Could not remove the unused page #{blank.id}: #{error}"
  ## The deletions that the room no longer refers to
  dropped = if redoOf? then [redoOf] else redo
  overflow = undo.length + 1 - historyLimit
  dropped = dropped.concat undo[...overflow] if overflow > 0
  forgetDeletions roomId, dropped
  ## Cursors on deleted pages are not worth keeping.
  try
    Remotes.remove
      room: roomId
      page: $in: pageIds
    , channel: "rooms::#{roomId}::remotes"
  catch error
    console.error "Could not clear the cursors of room #{roomId}: #{error}"
  blank.id if addBlank

## What the client shows right away for `deleteStep`, before the server answers
deleteStub = (roomId, requested, redoOf, blank) ->
  room = Rooms.findOne roomId
  return unless room?
  pages = room.pages ? []
  wanted = requested
  if redoOf?
    return unless topOf(room.redo) == redoOf
    wanted = PageDeletions.findOne(redoOf)?.ids ? []
  wanted = new Set wanted
  pageIds = (pageId for pageId in pages when wanted.has pageId)
  return unless pageIds.length
  if pageIds.length == pages.length
    return unless blank?
    Pages.insert blankPage(roomId, blank, {}),
      channel: pagesChannel roomId
    Rooms.update roomId, $set: pages: [blank.id]
    return blank.id
  deleting = new Set pageIds
  Rooms.update roomId, $set: pages: (pageId for pageId in pages when not deleting.has pageId)
  return

## Undo the deletion `id`, if it is the one at the end of `undo`: put back its
## pages that are not in the room, next to their old neighbors (see
## `planOrderRestore`), all in the one update described at the top.  Returns the
## IDs of the pages that came back, or `null` if it was not the latest deletion
## that can be undone (so nothing was done).
undoStep = (id, token, isSimulation) ->
  deletion = PageDeletions.findOne id
  return null unless deletion?
  roomId = deletion.room
  for [1..planAttempts]
    room = checkRoom roomId
    return null unless topOf(room.undo) == id
    pages = room.pages ? []
    missing = (pageId for pageId in deletion.ids when pageId not in pages)
    {pages: newPages} = planOrderRestore pages, deletion.order, missing
    if isSimulation
      Rooms.update roomId, $set: pages: newPages
      return missing
    redo = room.redo ? []
    applied = updateRoom roomId, unchanged(room),
      $set: pages: newPages
      $inc: rev: 1
      $pop: undo: 1
      $push: redo: {$each: [id], $slice: -historyLimit}
    , (current) -> id in (current.redo ? [])
    continue unless applied  # someone changed the room in between: plan again
    overflow = redo.length + 1 - historyLimit
    forgetDeletions roomId, redo[...overflow] if overflow > 0
    ## Each browser shows pages that were brought back zoomed to fit, once
    if token?
      try
        for pageId in missing
          Pages.update pageId, {$set: restored: token},
            channel: pagesChannel roomId
      catch error
        console.error "Could not mark the restored pages of room #{roomId}: #{error}"
    return missing
  throw new Meteor.Error "The pages of room #{roomId} keep changing"

validKind = (kind) -> kind in deletionKinds

## What a new blank page needs: the ID it gets (made by the caller, see
## `blankPage`), and how it looks
blankPattern =
  id: Match.Where validId
  grid: Match.Optional Boolean
  gridType: Match.Optional Match.Where validGridType

deleteOptions = Match.Optional
  redoOf: Match.Optional String
  blank: Match.Optional blankPattern

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
    pageId = Pages.insert page, channel: pagesChannel roomId
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
    ## Not part of a new page: the marker of restoring a page
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

  ## Delete pages.  Nothing is removed from the database: the pages just leave
  ## the room's list of pages, and the deletion is added to the room's history
  ## (see the top), so that `pagesRestore` can put the pages back where they
  ## were.  `kind` is which of the four ways to delete this is.  `options` can
  ## have `redoOf`, the deletion being redone (it must be the latest one that was
  ## undone; then `pageIds` is not used but its pages are deleted), and `blank`,
  ## what a new blank page needs (its `id`, and how it looks) if deleting leaves
  ## the room with no page.
  ## Returns the ID of the blank page, if one was added.
  pagesDel: (pageIds, remoteId, kind, options = {}) ->
    check pageIds, [String]
    check remoteId, Match.Optional String
    check kind, Match.Optional Match.Where validKind
    check options, deleteOptions
    requested = Array.from new Set pageIds
    throw new Meteor.Error "No pages to delete" unless requested.length
    roomId = checkPage(requested[0]).room
    for pageId in requested
      unless checkPage(pageId).room == roomId
        throw new Meteor.Error "Page #{pageId} is not in room #{roomId}"
    ## The blank page's ID comes from the caller (`options.blank.id`), because an
    ## ID made here would differ between the client's run of this method and the
    ## server's (`Random.id()` is not shared between them), and then what the
    ## person draws on the page right away would be rejected by the server.
    ## The deletion's ID is made by the server alone, which is the only one to
    ## save it.
    if @isSimulation
      deleteStub roomId, requested, options.redoOf, options.blank
    else
      deleteStep roomId, requested, remoteId, kind, options.redoOf, options.blank, Random.id()

  ## Undo deletions (`PageDeletions` of one room, which anyone in the room can
  ## do): put back their pages that are not in the room, next to the pages that
  ## were their neighbors (see `planOrderRestore`).  Only the latest deletion
  ## that has not been undone can be undone (then the one before it, if that is
  ## named too): a deletion that is not the latest one is left alone, and so is
  ## every deletion after it.  Each undone deletion can then be redone.  The
  ## pages get a `restored` marker (`token`) so that each browser can show them
  ## zoomed to fit the first time it opens them.  No page is ever removed.
  ## Returns the restored page IDs.
  pagesRestore: (deletionIds, token) ->
    check deletionIds, [String]
    check token, Match.Optional Number
    deletionIds = Array.from new Set deletionIds
    throw new Meteor.Error "No deletions to undo" unless deletionIds.length
    restored = []
    for id in deletionIds
      back = undoStep id, token, @isSimulation
      break unless back?
      restored.push back...
    restored

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
