## Deleting pages is reversible.  Pages are only taken out of the room's page
## list; their objects and history stay in the database.  This module deletes
## pages, runs the Undo Delete and Redo Delete buttons (which are separate from
## the normal Undo/Redo) on the room's history of deletions, which is the same
## for everyone in the room and is kept on the server (see /lib/pages.coffee and
## /lib/pageHistory.coffee), and shows the prompt offering to bring back pages
## that someone else deleted.

import {createEffect, createRoot, Show} from 'solid-js'
import {Random} from 'meteor/random'
import {createTracker} from 'solid-meteor-data'

import {currentPage, currentRoom, gotoPageId} from './AppState'
import {defaultGrid, defaultGridType} from './Grid'
import storage from './lib/storage'
import {StorageSet} from './lib/storageSet'
import {validId} from '/lib/id'
import {deletionKinds, historyChoices, noticeFor, noticeText, topOf} from '/lib/pageHistory'

## Identifies this browser (all its tabs), to not ask it about its own deletions
browserId = null
try
  browserId = window.localStorage.getItem 'browserId'
unless validId browserId
  browserId = Random.id()
  try
    window.localStorage.setItem 'browserId', browserId

## Deletions that this browser has already answered about in each room, as a
## set of deletion IDs, saved one by one (see ./lib/storageSet).  `seen` is
## `null` until the room is first opened in this browser, when nothing counts
## as new.
acks = {}
getAck = (roomId) ->
  acks[roomId] ?=
    seen: new storage.Variable "#{roomId}.deletionsSeen", null
    answered: new StorageSet "#{roomId}.deletionsAnswered.", (item, id) -> item == id
addAnswered = (roomId, deletionIds) ->
  {answered} = getAck roomId
  answered.load()
  for id in deletionIds when not answered.has id
    answered.put id, id
  return

## The deletions of the room that the history may refer to.  Reactive.
deletionsOf = (roomId) ->
  PageDeletions.find(room: roomId).fetch()

## Go to a page, wait until it is displayed, and then call `callback`.
## This way, the page being viewed never disappears from under the viewer.
gotoThen = (pageId, callback) ->
  return callback() if currentPage()?.id == pageId
  done = false
  timer = dispose = null
  run = ->
    return if done
    done = true
    clearTimeout timer
    dispose?()
    callback()
  timer = setTimeout run, 1500  # in case navigation never completes
  createRoot (d) ->
    dispose = d
    createEffect -> run() if currentPage()?.id == pageId
  gotoPageId pageId
  return

## The page to show in place of the current page once `ids` are deleted:
## the page that takes its place, or the last page if there is none.
## `undefined` if the current page is not being deleted.
replacementFor = (ids) ->
  pages = currentRoom()?.data()?.pages
  current = currentPage()?.id
  return unless pages? and current? and current in ids
  index = pages.indexOf current
  for page in pages[index+1..] when page not in ids
    return page
  for page in pages[...index] by -1 when page not in ids
    return page
  return

## What a new blank page is made like: like the current page
blankOptions = ->
  data = currentPage()?.data()
  grid: data?.grid ? defaultGrid
  gridType: data?.gridType ? defaultGridType

## Delete `ids` from the room, after going to `target` (if any), so that the
## page being viewed never disappears from under the viewer.  The server adds
## the deletion to the room's history.  `kind` is which of the four ways to
## delete this is, and `redoOf` the deletion that is being redone, if any.  If
## this deletes every page, the server leaves a new blank page (made like the
## current page) and it is shown.
removePages = (ids, target, kind, redoOf) ->
  room = currentRoom()
  return unless room?
  run = ->
    order = room.data()?.pages ? []
    present = (id for id in order when id in ids)
    return unless present.length
    ## The ID of a new blank page is made here, so that the page shown at once is the page the server saves
    options = {blank: Object.assign {id: Random.id()}, blankOptions()}
    options.redoOf = redoOf if redoOf?
    blankId = Meteor.apply 'pagesDel', [present, browserId, kind, options],
      returnStubValue: true
    , (error) ->
      if error?
        console.error "Failed to delete pages on server: #{error}"
    gotoPageId blankId if blankId
  if target?
    gotoThen target, run
  else
    run()
  return

## Undo deletions, for everyone: bring back their pages that are not in the room
## (see `pagesRestore`).
undoDeletions = (deletionIds) ->
  Meteor.call 'pagesRestore', deletionIds, Date.now(), (error) ->
    if error?
      console.error "Failed to restore pages on server: #{error}"
  return

## What the Undo Delete and Redo Delete buttons would do right now, as
## `{undo, redo}`, each `{id, ask}` (the question to ask) or missing if there is
## nothing to do.  Everyone in the room gets the same answer.  Reactive.
export historyInfo = ->
  room = currentRoom()
  pages = room?.data()?.pages
  return {} unless room? and pages?
  historyChoices room.data(), deletionsOf(room.id), pages

## Delete pages.  `kind` is which of the four choices this is.  If this deletes
## every page, the room is left with a new blank page.  The deletion is added to
## the room's history for Undo Delete.
export deletePages = (ids, {kind} = {}) ->
  return unless currentRoom()?
  removePages ids, replacementFor(ids), (if kind in deletionKinds then kind else 'current')
  return

## Undo Delete, for the deletion that was asked about: bring back its pages that
## are missing, next to their old neighbors.  Never deletes any page, and the
## page being viewed stays open.  Does nothing if it is not the latest deletion
## that can be undone any more.
export undoDelete = (id) ->
  return unless currentRoom()?
  undoDeletions [id]

## Redo Delete, for the deletion that was asked about: delete its pages that are
## in the room (never any page added since).  The page being viewed stays open,
## unless it is deleted, when its replacement is shown.  Does nothing if it is
## not the deletion undone last any more.
export redoDelete = (id) ->
  room = currentRoom()
  return unless room?
  deletion = PageDeletions.findOne id
  return unless deletion?.room == room.id and topOf(room.data()?.redo) == id
  pages = room.data()?.pages ? []
  ids = (pageId for pageId in deletion.ids when pageId in pages)
  return unless ids.length
  removePages ids, replacementFor(ids), deletion.kind, deletion._id
  return

## Offer to bring back the pages of the latest deletion of the room, when
## someone else made it, as soon as it happens (if the room is open here) and
## when opening the room later.  Any person can bring the pages back for
## everyone.  Answering "No" only hides the question in this browser: the
## deletion stays in the room's history, to undo with Undo Delete.  A later
## deletion replaces the question, as if it were answered No.
export DeletedNotice = ->
  loaded = createTracker ->
    room = currentRoom()
    Boolean room? and not room.loading() and room.data()?.pages?

  ## The first time a room is open in this browser, nothing is new.
  createEffect ->
    return unless loaded()
    roomId = currentRoom().id
    ack = getAck roomId
    return if ack.seen.get()?
    ack.answered.load()
    ids = (deletion._id for deletion in deletionsOf roomId)
    latest = currentRoom().data().latest
    ids.push latest if latest? and latest not in ids
    for id in ids when not ack.answered.has id
      ack.answered.put id, id
    ack.seen.set true

  ## The latest deletion of the room, if this browser did not make it and has
  ## not answered about it
  info = createTracker ->
    return unless loaded()
    room = currentRoom()
    ack = getAck room.id
    return unless ack.seen.get()?
    notice = noticeFor room.data(), deletionsOf(room.id), room.data().pages,
      browserId: browserId
      answered: (id) -> ack.answered.has id
    return unless notice?
    Object.assign {room: room.id}, notice

  text = ->
    return '' unless (state = info())?
    noticeText state.numbers
  bringBack = ->
    return unless (state = info())?
    undoDeletions state.ids
    addAnswered state.room, state.ids
  dismiss = ->
    return unless (state = info())?
    addAnswered state.room, state.ids

  <Show when={info()}>
    <div class="pageDelNotice" role="alertdialog">
      <p>{text()}</p>
      <div class="pageDelButtons">
        <button type="button" onClick={bringBack}>Yes</button>
        <button type="button" onClick={dismiss}>No</button>
      </div>
    </div>
  </Show>
