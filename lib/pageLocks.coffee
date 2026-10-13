## Page locks, worked out from a room's document.  (The rules are explained in
## /lib/pages.coffee.)  Nothing here touches the database or the screen, so it
## can run (and be tested) anywhere.
##
## A room's `locks` is a list of `{page, by}`: one lock for each browser that
## has locked a page (the same one for all the tabs of a browser).  A page is
## locked while at least one lock refers to it.
##
## `by` is the owner of the lock: not the browser's ID, which is public, but the
## SHA-256 of a secret key that the browser keeps to itself (see `lockOwner`).
## Everyone in the room sees the owners of the locks, and nobody can work out
## the key from an owner, so only the browser with the key can name the owner
## and so remove the lock.

import {sha256} from './sha256'

## What a lock key looks like: the characters of `Random.secret()`, 32 or more
export validLockKey = (key) ->
  typeof key == 'string' and /^[A-Za-z0-9_-]{32,128}$/.test key

## The owner (the `by` of locks) of the browser that has the secret key `key`
export lockOwner = (key) -> sha256 key

## The IDs of the pages that are locked, as a `Set`
export lockedPages = (room) ->
  new Set (lock.page for lock in room?.locks ? [])

## Whether the owner `holder` has a lock on the page
export holdsLock = (room, pageId, holder) ->
  (room?.locks ? []).some (lock) -> lock.page == pageId and lock.by == holder

## How many owners (browsers) have a lock on the page
export lockCount = (room, pageId) ->
  holders = new Set
  for lock in room?.locks ? [] when lock.page == pageId
    holders.add lock.by
  holders.size

## Who has locked a page, from the point of view of the owner `holder`: how many
## owners have a lock on it, whether `holder` is one of them, and how many others
## are
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
