## Page locks, worked out from a room's document.  (The rules are explained in
## /lib/pages.coffee.)  Nothing here touches the database or the screen, so it
## can run (and be tested) anywhere, and it imports nothing.
##
## A room's `locks` is a list of `{page, by}`: one lock for each browser (`by`,
## the same ID for all the tabs of a browser) that has locked a page.  A page is
## locked while at least one lock refers to it.

## The IDs of the pages that are locked, as a `Set`
export lockedPages = (room) ->
  new Set (lock.page for lock in room?.locks ? [])

## Whether the browser `holder` has a lock on the page
export holdsLock = (room, pageId, holder) ->
  (room?.locks ? []).some (lock) -> lock.page == pageId and lock.by == holder

## How many browsers have a lock on the page
export lockCount = (room, pageId) ->
  holders = new Set
  for lock in room?.locks ? [] when lock.page == pageId
    holders.add lock.by
  holders.size

## Who has locked a page, from the point of view of the browser `holder`: how
## many browsers have a lock on it, whether `holder` is one of them, and how many
## others are
export lockSummary = (room, pageId, holder) ->
  count = lockCount room, pageId
  mine = holdsLock room, pageId, holder
  {count, mine, others: count - (if mine then 1 else 0)}

## Split page IDs into the ones that a deletion can delete and the ones that are
## locked and stay, each in the order given
export splitLocked = (room, ids) ->
  locked = lockedPages room
  deletable: (id for id in ids when not locked.has id)
  stays: (id for id in ids when locked.has id)
