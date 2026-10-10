import {check, Match} from 'meteor/check'
import {Mongo} from 'meteor/mongo'
import {Random} from 'meteor/random'

import {validId} from './id'
import {checkRoom} from './rooms'
import {defaultGridType, validGridType} from './grid'
import {deletionKinds, historyLimit} from './pageHistory'
import {planOrderRestore} from './pageOrder'

@Pages = new Mongo.Collection 'pages'

## The history of deleting pages, the same for everyone in a room, so that
## anyone can undo and redo anyone's deletion (see ./pageHistory).
@PageDeletions = new Mongo.Collection 'pageDeletions'

## Every change to `PageDeletions` of a room is on this channel
deletionsChannel = (roomId) -> "rooms::#{roomId}::pageDeletions"

## How often `pagesDel` and `pagesRestore` plan again when the room's pages
## keep changing.  Each time they plan again, some other change has succeeded,
## so this is only a limit for a runaway loop.
planAttempts = 1000

export checkPage = (page) ->
  if validId(page) and data = Pages.findOne page
    data
  else
    throw new Meteor.Error "Invalid page ID #{page}"

## Every deletion and every undo of a room takes the next number of the room
## (`deletionSeq` of the room), which orders the history: the numbers are
## unique and grow in the order the changes were made, however close together
## they are.  A deletion takes its number in the very update that removes its
## pages from the room (see `pagesDel`), so the order of the history is exactly
## the order in which the pages left the room.  An undo takes its number here.
## The update applies only if nobody took that number first.
takeNumber = (roomId) ->
  for [1..planAttempts]
    last = checkRoom(roomId).deletionSeq
    number = (last ? 0) + 1
    selector = _id: roomId
    selector.deletionSeq = if last? then last else $exists: false
    return number if Rooms.update selector, $set: deletionSeq: number
  throw new Meteor.Error "The history of room #{roomId} keeps changing"

## Forget the oldest deletions of a room beyond the newest `historyLimit` in
## each state.  (This only forgets how to undo and redo them: the pages and
## everything on them stay in the database.)
pruneDeletions = (roomId) ->
  for state in ['undo', 'redo']
    extra = PageDeletions.find {room: roomId, state},
      sort: {moved: -1, _id: -1}
      skip: historyLimit
      fields: {_id: 1}
    .map (deletion) -> deletion._id
    if extra.length
      PageDeletions.remove {_id: {$in: extra}, room: roomId, state},
        channel: deletionsChannel roomId
  return

## Add a deletion to the history of its room, where it can be undone.
## `deletion.seq` is the number the deletion took from the room.  Once this is
## done, the deletion is complete.
addDeletion = (roomId, deletion) ->
  PageDeletions.insert Object.assign({}, deletion,
    room: roomId
    state: 'undo'
    moved: deletion.seq
  ), channel: deletionsChannel roomId
  return

## What a new deletion (number `seq`) ends: what could be redone before it (not
## what was undone after it), except that redoing a deletion (`redoOf`) only
## ends that one.  Then forget the oldest deletions beyond the limit.  (Until
## this is done, `pagesDel` already refuses to redo what a new deletion ended.)
endRedoable = (roomId, seq, redoOf) ->
  selector = {room: roomId, state: 'redo', moved: $lt: seq}
  selector._id = redoOf if redoOf?
  PageDeletions.remove selector, channel: deletionsChannel roomId
  pruneDeletions roomId
  return

## Put the pages of `ids` that are not in the room back in its page list, next to
## the pages that were their neighbors in `order` (see `planOrderRestore`).  The
## new list is written in a single update, which applies only if the room's page
## list is still the one the plan was made from.  If someone changed it in
## between (adding, deleting, or restoring pages), plan again from the new list,
## so that the pages never land in the wrong places.  All of the pages come back
## in that one update.  Returns the IDs of the pages that came back (`missing`)
## and, for each of them, the ID of the deletion marker it had when planning
## (`deletedIds`).
putBack = (roomId, order, ids, isSimulation) ->
  missing = []
  deletedIds = {}
  for attempt in [1..planAttempts]
    room = checkRoom roomId
    pages = room.pages ? []
    missing = (pageId for pageId in ids when pageId not in pages)
    break unless missing.length
    deletedIds = {}
    deletedIds[pageId] = Pages.findOne(pageId)?.deleted?.id for pageId in missing
    {pages: newPages} = planOrderRestore pages, order, missing
    if isSimulation
      Rooms.update roomId, $set: pages: newPages
      break
    selector = _id: roomId
    selector.pages = if room.pages? then pages else $exists: false
    break if Rooms.update selector, $set: pages: newPages
    if attempt == planAttempts
      throw new Meteor.Error "The pages of room #{roomId} keep changing"
  {missing, deletedIds}

## Take back a deletion (its `pageIds`, from the page list `order`) whose pages
## left the room but which could not be completed because a database write
## failed, so that the pages are not left out of the room with no way to bring
## them back.  Whoever deleted them gets the error.
takeBack = (roomId, id, pageIds, order) ->
  try
    putBack roomId, order, pageIds
    for pageId in pageIds
      Pages.update {_id: pageId, 'deleted.id': id}, {$unset: deleted: ''},
        channel: "rooms::#{roomId}::pages"
  catch error
    console.error "Could not take back the deletion of pages #{pageIds} in room #{roomId}: #{error}"
  return

## Undo one deletion: put back its pages that are not in the room, next to their
## old neighbors, and make it something that can be redone.  The pages of the
## deletion all come back at once, in one update of the room's page list.
## Returns the IDs of the pages that came back.
restoreDeletion = (deletionId, token, isSimulation) ->
  deletion = PageDeletions.findOne deletionId
  return [] unless deletion?.state == 'undo'  # (e.g., someone undid it first)
  roomId = deletion.room
  moved = null
  try
    ## Take the deletion before undoing it, so that if two people undo it at the
    ## same moment, only one of them does (and what the other one sees is a
    ## deletion that is undone already).
    moved = if isSimulation then Date.now() else takeNumber roomId
    taken = PageDeletions.update {_id: deletionId, state: 'undo'},
      $set: {state: 'redo', moved}
    , channel: deletionsChannel roomId
    return [] unless taken
    ## A new deletion that took its number after this undo took its own ended
    ## redoing this one, but may have cleared the redo list before the deletion
    ## got here.  Then there is nothing to redo.
    unless isSimulation or moved > (checkRoom(roomId).lastDeletion ? 0)
      PageDeletions.remove {_id: deletionId, state: 'redo', moved},
        channel: deletionsChannel roomId
    {missing, deletedIds} =
      putBack roomId, deletion.order, deletion.ids, isSimulation
  catch error
    ## Nothing was undone, so the deletion can still be undone (even if someone's
    ## new deletion has forgotten it meanwhile, as it ends what could be redone)
    if moved?
      back = PageDeletions.update {_id: deletionId, state: 'redo', moved},
        $set: {state: 'undo', moved: deletion.moved}
      , channel: deletionsChannel roomId
      unless back or isSimulation or PageDeletions.findOne deletionId
        PageDeletions.insert deletion, channel: deletionsChannel roomId
    throw error
  ## Clear the deletion marker, but only the one these pages were restored
  ## from (the one seen when planning, or none): if someone deleted one of
  ## them again meanwhile, its new marker must stay, so that it can be undone.
  for pageId in missing
    selector = _id: pageId
    unless isSimulation
      selector['deleted.id'] = deletedIds[pageId] ? $exists: false
    modifier = $unset: deleted: ''
    modifier.$set = restored: token if token?
    Pages.update selector, modifier, channel: "rooms::#{roomId}::pages"
  pruneDeletions roomId unless isSimulation
  missing

validKind = (kind) -> kind in deletionKinds

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
  ## page list and get marked `deleted` (an `id` of this deletion, when, and by
  ## whom), and the deletion is added to the room's history (`PageDeletions`),
  ## so that `pagesRestore` can put the pages back where they were.
  ## `kind` is which of the four ways to delete this is, and `redoOf` is the
  ## deletion being redone, if it is (it must be one that was undone).
  ## Returns the time of deletion (in milliseconds) from the server.
  pagesDel: (pageIds, remoteId, kind, redoOf) ->
    check pageIds, [String]
    check remoteId, Match.Optional String
    check kind, Match.Optional Match.Where validKind
    check redoOf, Match.Optional String
    requested = Array.from new Set pageIds
    throw new Meteor.Error "No pages to delete" unless requested.length
    roomId = checkPage(requested[0]).room
    for pageId in requested
      unless checkPage(pageId).room == roomId
        throw new Meteor.Error "Page #{pageId} is not in room #{roomId}"
    ## The pages are removed from the room in a single update, which applies only
    ## if the room's page list is still the one the plan was made from.  If
    ## someone changed it in between (adding, deleting, or restoring pages), plan
    ## again from the new list.  This also makes the check that a page remains
    ## atomic, and keeps two deletions that overlap from both claiming a page.
    ## The same update gives the deletion its number in the room's history, so
    ## deletions are in the history in the order their pages left the room.
    for attempt in [1..planAttempts]
      room = checkRoom roomId
      pages = room.pages ? []
      ## Pages that are already deleted (e.g. by someone else at the same time)
      ## stay deleted.
      pageIds = (pageId for pageId in requested when pageId in pages)
      return unless pageIds.length
      if pages.every((pageId) -> pageId in pageIds)
        throw new Meteor.Error "Cannot delete every page in a room"
      if redoOf? and not @isSimulation
        redone = PageDeletions.findOne _id: redoOf, room: roomId, state: 'redo'
        throw new Meteor.Error "There is nothing to redo" unless redone?
        ## A new deletion ends what could be redone before it.  Its record clears
        ## those a moment after the pages left the room, so also check the room's
        ## number of the latest new deletion, which changed in the same update.
        unless redone.moved > (room.lastDeletion ? 0)
          throw new Meteor.Error "There is nothing to redo"
        kind = redone.kind
      ## Remove pages from the room first, so that clients stop showing them.
      if @isSimulation
        Rooms.update roomId, $pullAll: pages: pageIds
        break
      ## The deletion takes the room's next number in the same update.  A new
      ## deletion (not a redo) is also the latest one, which ends redoing
      ## whatever was undone before its number.
      seq = (room.deletionSeq ? 0) + 1
      selector = {_id: roomId, pages}
      selector.deletionSeq = if room.deletionSeq? then room.deletionSeq else $exists: false
      numbers = {deletionSeq: seq}
      numbers.lastDeletion = seq unless redoOf?
      removed = Rooms.update selector,
        $pullAll: pages: pageIds
        $set: numbers
      break if removed
      if attempt == planAttempts
        throw new Meteor.Error "The pages of room #{roomId} keep changing"
    at = new Date unless @isSimulation
    ## `id` tells this deletion from any other deletion of the same pages, even
    ## one made at the very same moment.  Each page is marked after being removed,
    ## so that no overlapping `pagesRestore` (which clears only the marker it
    ## started from) can leave it without a marker.  The deletion is complete
    ## when its record is added, which is the last of these writes: if one of them
    ## fails before that, the pages are taken back, so that a deletion of several
    ## pages is never left half done.
    id = Random.id()
    try
      for pageId in pageIds
        deleted = {id}
        deleted.by = remoteId if remoteId?
        deleted.at = at if at?
        Pages.update pageId,
          $set: {deleted}
        , channel: "rooms::#{roomId}::pages"
      unless @isSimulation
        deletion = {_id: id, seq, kind: kind ? 'current', ids: pageIds, order: pages, at}
        deletion.by = remoteId if remoteId?
        addDeletion roomId, deletion
    catch error
      unless @isSimulation or PageDeletions.findOne id
        takeBack roomId, id, pageIds, pages
      throw error
    unless @isSimulation
      endRedoable roomId, seq, redoOf
      ## Cursors on deleted pages are not worth keeping.
      Remotes.remove
        room: roomId
        page: $in: pageIds
      , channel: "rooms::#{roomId}::remotes"
    at?.getTime()

  ## Undo deletions (`PageDeletions` of one room, any that can be undone, which
  ## anyone in the room can do): put back their pages that are not in the room,
  ## next to the pages that were their neighbors (see `planOrderRestore`).
  ## Pages come back newest deletion first, so that each deletion finds the pages
  ## around it as they were.  Each deletion can then be redone.  The pages get a
  ## `restored` marker (`token`) so that each browser can show them zoomed to fit
  ## the first time it opens them.  Deletions that were undone already are
  ## ignored, and no page is ever removed.  Returns the restored page IDs.
  pagesRestore: (deletionIds, token) ->
    check deletionIds, [String]
    check token, Match.Optional Number
    deletionIds = Array.from new Set deletionIds
    throw new Meteor.Error "No deletions to undo" unless deletionIds.length
    deletions = (PageDeletions.findOne id for id in deletionIds)
    deletions = (deletion for deletion in deletions when deletion?)
    return [] unless deletions.length
    for deletion in deletions when deletion.room != deletions[0].room
      throw new Meteor.Error "Deletions of different rooms"
    deletions.sort (a, b) -> b.moved - a.moved or (if a._id < b._id then 1 else -1)
    restored = []
    for deletion in deletions
      restored.push restoreDeletion(deletion._id, token, @isSimulation)...
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
