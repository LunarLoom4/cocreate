## Deleting pages is reversible.  Pages are only taken out of the room's page
## list and marked `deleted` (see /lib/pages.coffee); their objects and history
## stay in the database.  This module deletes pages, keeps the history of this
## browser's deletions for the Undo Delete and Redo Delete buttons (which are
## separate from the normal Undo/Redo), and shows the prompt offering to bring
## back pages that someone else deleted.

import {createEffect, createRoot, Show} from 'solid-js'
import {Random} from 'meteor/random'
import {createTracker} from 'solid-meteor-data'

import {currentPage, currentRoom, gotoPageId} from './AppState'
import {defaultGrid, defaultGridType} from './Grid'
import storage from './lib/storage'
import {validId} from '/lib/id'
import {planOrderRestore, planRestore} from '/lib/pageOrder'

## Identifies this browser (all its tabs), to not ask it about its own deletions
browserId = null
try
  browserId = window.localStorage.getItem 'browserId'
unless validId browserId
  browserId = Random.id()
  try
    window.localStorage.setItem 'browserId', browserId

## Some things are remembered by this browser (see ./lib/storage), and every
## tab of it has its own copy, which is told about changes made by other tabs
## a moment after they happen.  Anything saved as a whole (a list) must
## therefore be read afresh right before it is changed, or a tab would write back
## what it knew before, and undo what another tab just did.
##
## Keys of the variables whose last save did not make it to the browser's
## storage (it may be full or off): for them, the copy in memory is the newest.
unsaved = new Set

## Bring `variable` up to date with what is saved in this browser.
refresh = (variable) ->
  return variable if unsaved.has variable.key
  try
    json = window.localStorage.getItem variable.key
    if json? and json != variable.constructor.stringify variable.get()
      variable.setTemp variable.constructor.parse json
  return variable

## Set `variable`, and note whether it could be saved.
save = (variable, value) ->
  variable.set value
  try
    saved = window.localStorage.getItem(variable.key) ==
            variable.constructor.stringify value
  if saved
    unsaved.delete variable.key
  else
    unsaved.add variable.key
  return

## Deletions that this browser has already answered about in each room, as a
## list of deletion times (milliseconds).  It is `null` until the room is first
## opened in this browser, when nothing counts as new.
acks = {}
getAck = (roomId) ->
  acks[roomId] ?= new storage.Variable "#{roomId}.pagesSeen", null
addAck = (roomId, times) ->
  variable = refresh getAck roomId
  current = variable.get() ? []
  added = (time for time in times when time? and time not in current)
  save variable, current.concat added if added.length
  return

deletedPages = (roomId) ->
  Pages.find
    room: roomId
    deleted: $exists: true
  .fetch()

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

## Delete `ids` from the room, after going to `target` (if any), so that the
## page being viewed never disappears from under the viewer.  `sent(present,
## order)` is called as the deletion is sent, with the pages that are really
## being deleted and the room's page list from right before; what it returns
## is given to `failed` if the server then refuses the deletion, or to
## `accepted` if it accepts it.
removePages = (ids, target, sent, failed, accepted) ->
  room = currentRoom()
  return unless room?
  run = ->
    order = room.data()?.pages ? []
    present = (id for id in order when id in ids)
    return unless present.length
    result = sent? present, order[..]
    Meteor.call 'pagesDel', present, browserId, (error) ->
      if error?
        console.error "Failed to delete pages on server: #{error}"
        failed? result
      else
        accepted? result
  if target?
    gotoThen target, run
  else
    run()
  return

## A new blank page at the end, like the current page, in which to land when
## every page is deleted.  Returns its ID.
makeBlank = (room) ->
  data = currentPage()?.data()
  Meteor.apply 'pageNew', [
    room: room.id
    grid: data?.grid ? defaultGrid
    gridType: data?.gridType ? defaultGridType
  ],
    returnStubValue: true
  , (error) ->
    if error?
      console.error "Failed to create new page on server: #{error}"

## Bring back pages for everyone, where they were (see `pagesRestore`).
## This is for the "Bring them back?" prompt; Undo Delete does its own.
export restorePages = (ids) ->
  Meteor.call 'pagesRestore', ids, Date.now(), (error) ->
    if error?
      console.error "Failed to restore pages on server: #{error}"
  return

## ---------------------------------------------------------------------------
## History of this browser's deletions, for Undo Delete and Redo Delete.
##
## Each deletion is one entry, however many pages it deleted:
##   {id, kind, ids, order, at}
## where `kind` is 'current', 'left', 'right', or 'all' (the four ways to
## delete), `ids` are the pages it deleted, and `order` is the room's page list
## right before the deletion, which is how its pages find their way back (see
## `planOrderRestore`: by their neighbors, never by page number).
##
## The newest `historyLimit` deletions are kept for each room.  They are saved
## in this browser, so they survive a reload and are shared by its tabs.
## Nothing here is connected to the normal Undo/Redo (Ctrl-Z/Ctrl-Y).

export historyLimit = 40
kinds = ['current', 'left', 'right', 'all']

histories = {}
getHistory = (roomId) ->
  histories[roomId] ?= new storage.Variable "#{roomId}.pageDeletes",
    undo: []
    redo: []

isStringList = (list) ->
  Array.isArray(list) and list.every (item) -> typeof item == 'string'
validEntry = (entry) ->
  entry? and typeof entry.id == 'string' and entry.kind in kinds and
  isStringList(entry.ids) and entry.ids.length > 0 and
  isStringList(entry.order)
validEntries = (list) ->
  return [] unless Array.isArray list
  entry for entry in list when validEntry entry

## The two lists (oldest first), ignoring anything malformed in storage.
## Before changing the history, read it `fresh` (see `refresh`).
readHistory = (roomId, fresh) ->
  variable = getHistory roomId
  refresh variable if fresh
  value = variable.get()
  undo: validEntries value?.undo
  redo: validEntries value?.redo

writeHistory = (roomId, undo, redo) ->
  save getHistory(roomId),
    undo: undo[-historyLimit..]
    redo: redo[-historyLimit..]
  return

## A new deletion: it can be undone, and what could be redone before it can't
## be any more.  Those entries are forgotten only once the server accepts the
## deletion (see `acceptDeletion`), so a refused deletion leaves them alone.
## Returns their ids.
addDeletion = (roomId, entry) ->
  {undo, redo} = readHistory roomId, true
  undo.push entry
  writeHistory roomId, undo, redo
  (e.id for e in redo)

## The server accepted a deletion: forget the redo entries `forgotten`.
acceptDeletion = (roomId, forgotten) ->
  {undo, redo} = readHistory roomId, true
  writeHistory roomId, undo, (e for e in redo when e.id not in forgotten)
  return

## The server refused a deletion, so there is nothing to undo.
dropEntry = (roomId, id) ->
  {undo, redo} = readHistory roomId, true
  writeHistory roomId,
    (e for e in undo when e.id != id)
    (e for e in redo when e.id != id)
  return

## Move entry `id` from list `from` to list `to` (as `replacement`, if given).
moveEntry = (roomId, from, to, id, replacement) ->
  history = readHistory roomId, true
  entry = history[from].find (e) -> e.id == id
  return unless entry?
  history[from] = (e for e in history[from] when e.id != id)
  history[to].push replacement ? entry
  writeHistory roomId, history.undo, history.redo
  return

## What Undo Delete would do for `entry`: bring back the pages of the deletion
## that are not in the room now, and the numbers they will have.  `undefined`
## if all of them are back already (e.g., someone brought them back).
undoPlan = (entry, pages) ->
  missing = (id for id in entry.ids when id not in pages)
  return unless missing.length
  placed = planOrderRestore(pages, entry.order, missing).pages
  numbers = (placed.indexOf(id) + 1 for id in missing).sort (a, b) -> a - b
  others = pages.some (id) -> id not in entry.ids
  {entry, missing, numbers, others}

## What Redo Delete would do for `entry`: delete its pages that are in the room.
## `blank` is whether that would leave no page at all, so that a blank page
## gets added first.
redoPlan = (entry, pages) ->
  present = (id for id in entry.ids when id in pages)
  return unless present.length
  numbers = (pages.indexOf(id) + 1 for id in present).sort (a, b) -> a - b
  {entry, present, numbers, blank: present.length == pages.length}

## "Page 3", "Pages 3 and 4", "Pages 1 to 4"
pagesLabel = (numbers) ->
  if numbers.length == 1
    "Page #{numbers[0]}"
  else
    "Pages #{listPages numbers}"

undoAsk = ({entry, missing, numbers, others}) ->
  all = entry.kind == 'all' and missing.length == entry.ids.length and missing.length > 1
  what = if all then "all #{missing.length} pages" else pagesLabel numbers
  if entry.kind == 'all' and others
    "Bring back #{what}? The blank page stays."
  else
    "Bring back #{what}?"

redoAsk = ({entry, present, numbers, blank}) ->
  all = entry.kind == 'all' and present.length == entry.ids.length and present.length > 1
  what = if all then "all #{present.length} pages" else pagesLabel numbers
  if blank
    "Delete #{what} again? A blank page will be added."
  else
    "Delete #{what} again?"

## What the Undo Delete and Redo Delete buttons would do right now, as
## `{undo, redo}`, each `{id, ask}` (the question to ask) or missing if there is
## nothing to do.  The newest entry that still has something to do is used:
## entries whose pages were all brought back by someone else are skipped.
## Reactive.
export historyInfo = ->
  room = currentRoom()
  pages = room?.data()?.pages
  return {} unless room? and pages?
  {undo, redo} = readHistory room.id
  info = {}
  for entry in undo by -1 when (plan = undoPlan entry, pages)?
    info.undo = {id: entry.id, ask: undoAsk plan}
    break
  for entry in redo by -1 when (plan = redoPlan entry, pages)?
    info.redo = {id: entry.id, ask: redoAsk plan}
    break
  info

## Delete pages.  `kind` is which of the four choices this is.  With `blank`,
## first make a blank page, like the current page, so the room is left with it.
## The deletion is added to the history for Undo Delete.
export deletePages = (ids, {blank, kind} = {}) ->
  room = currentRoom()
  return unless room?
  if blank
    target = makeBlank room
    return unless target?
  else
    target = replacementFor ids
  removePages ids, target, (present, order) ->
    entry =
      id: Random.id()
      kind: if kind in kinds then kind else 'current'
      ids: present
      order: order
      at: Date.now()
    {entry, forgotten: addDeletion room.id, entry}
  , ({entry}) ->
    dropEntry room.id, entry.id
  , ({forgotten}) ->
    acceptDeletion room.id, forgotten
  return

## Undo Delete, for the entry that was asked about: bring back its pages that
## are missing, next to their old neighbors.  Never deletes any page, and the
## page being viewed stays open.
export undoDelete = (id) ->
  room = currentRoom()
  return unless room?
  entry = readHistory(room.id, true).undo.find (e) -> e.id == id
  return unless entry?
  pages = room.data()?.pages ? []
  missing = (pageId for pageId in entry.ids when pageId not in pages)
  return unless missing.length
  moveEntry room.id, 'undo', 'redo', id
  Meteor.call 'pagesRestore', missing, Date.now(), entry.order, (error) ->
    if error?
      console.error "Failed to restore pages on server: #{error}"
      moveEntry room.id, 'redo', 'undo', id
  return

## Redo Delete, for the entry that was asked about: delete its pages that are in
## the room (never any page added since).  The page being viewed stays open,
## unless it is deleted, when its replacement is shown.
export redoDelete = (id) ->
  room = currentRoom()
  return unless room?
  entry = readHistory(room.id, true).redo.find (e) -> e.id == id
  return unless entry?
  pages = room.data()?.pages ? []
  ids = (pageId for pageId in entry.ids when pageId in pages)
  return unless ids.length
  if ids.length == pages.length  # that is every page: leave a blank one
    target = makeBlank room
    return unless target?
  else
    target = replacementFor ids
  removePages ids, target, (present, order) ->
    moveEntry room.id, 'redo', 'undo', id,
      Object.assign {}, entry, {ids: present, order, at: Date.now()}
    entry
  , (original) ->
    moveEntry room.id, 'undo', 'redo', id, original
  return

## "5", "5 and 8", "1 to 4, 8 and 10"
listPages = (numbers) ->
  parts = []
  i = 0
  while i < numbers.length
    j = i
    j++ while j + 1 < numbers.length and numbers[j+1] == numbers[j] + 1
    if j - i >= 2
      parts.push "#{numbers[i]} to #{numbers[j]}"
    else
      for k in [i..j]
        parts.push "#{numbers[k]}"
    i = j + 1
  if parts.length <= 1
    parts[0] ? ''
  else
    "#{parts[...-1].join ', '} and #{parts[parts.length - 1]}"

## Offer to bring back pages that someone else deleted, as soon as it happens
## (if the room is open here) and when opening the room later.  Any person can
## bring the pages back for everyone.  Answering "No" only hides the question
## in this browser.
export DeletedNotice = ->
  loaded = createTracker ->
    room = currentRoom()
    Boolean room? and not room.loading() and room.data()?.pages?

  ## The first time a room is open in this browser, nothing is new.
  createEffect ->
    return unless loaded()
    roomId = currentRoom().id
    variable = refresh getAck roomId
    return if variable.get()?
    save variable, (
      for page in deletedPages roomId when page.deleted?.at?
        page.deleted.at.getTime()
    )

  ## Deleted pages that this browser has not answered about and did not delete
  info = createTracker ->
    return unless loaded()
    room = currentRoom()
    ack = getAck(room.id).get()
    return unless ack?
    pages = room.data().pages
    items = []
    for page in deletedPages room.id
      deleted = page.deleted
      continue if page._id in pages or not deleted?.at?
      time = deleted.at.getTime()
      continue if time in ack or deleted.by == browserId
      ## An empty page (e.g., the blank page of Delete All) has no work to bring back
      continue unless Objects.find({page: page._id}, limit: 1).count()
      items.push {id: page._id, time}
    return unless items.length
    items.sort (a, b) -> a.time - b.time
    ids = (item.id for item in items)
    ## Number the pages by where they would come back
    prevOf = (id) -> Pages.findOne(id)?.deleted?.prev
    placed = planRestore(pages, ids, prevOf).pages
    numbers = (placed.indexOf(id) + 1 for id in ids).sort (a, b) -> a - b
    {room: room.id, ids, numbers, times: Array.from new Set (item.time for item in items)}

  text = ->
    return '' unless (state = info())?
    if state.numbers.length == 1
      "Page #{state.numbers[0]} was deleted. Bring it back?"
    else
      "Pages #{listPages state.numbers} were deleted. Bring them back?"
  bringBack = ->
    return unless (state = info())?
    restorePages state.ids
    addAck state.room, state.times
  dismiss = ->
    return unless (state = info())?
    addAck state.room, state.times

  <Show when={info()}>
    <div class="pageDelNotice" role="alertdialog">
      <p>{text()}</p>
      <div class="pageDelButtons">
        <button type="button" onClick={bringBack}>Yes</button>
        <button type="button" onClick={dismiss}>No</button>
      </div>
    </div>
  </Show>
