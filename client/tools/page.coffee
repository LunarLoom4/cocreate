import {createEffect, createSignal, For, on as on_, onCleanup, Show} from 'solid-js'
import {Portal} from 'solid-js/web'

import {createTracker} from 'solid-meteor-data'

import {defineTool} from './defineTool'
import {currentRoom, currentPage, currentPageId, gotoPageId} from '../AppState'
import {defaultGrid, defaultGridType} from '../Grid'
import {deletePages, historyInfo, redoDelete, undoDelete} from '../PageTrash'
import {Icon, trashPath} from '../lib/icons'

defineTool
  name: 'pagePrev'
  category: 'page'
  icon: 'chevron-left-square'
  help: 'Go to previous page'
  hotkey: 'Page Up'
  click: ->
    pageId = currentRoom()?.pageDelta currentPage(), -1
    gotoPageId pageId if pageId?

defineTool
  name: 'pageNext'
  category: 'page'
  icon: 'chevron-right-square'
  help: 'Go to next page'
  hotkey: 'Page Down'
  click: ->
    pageId = currentRoom()?.pageDelta currentPage(), +1
    gotoPageId pageId if pageId?

defineTool
  name: 'pageNew'
  category: 'page'
  icon: 'plus-square'
  help: 'Add new blank page after the current page'
  click: ->
    page = currentPage()
    return unless page?
    index = currentRoom()?.pageIndex page
    return unless index?
    data = page.data()
    Meteor.call 'pageNew',
      room: currentRoom().id
      grid: data?.grid ? defaultGrid
      gridType: data?.gridType ? defaultGridType
    , index+1
    , (error, pageId) ->
      if error?
        return console.error "Failed to create new page on server: #{error}"
      gotoPageId pageId

defineTool
  name: 'pageDup'
  category: 'page'
  icon: 'clone'
  help: 'Duplicate current page'
  click: ->
    Meteor.call 'pageDup', currentPage().id, (error, pageId) ->
      if error?
        return console.error "Failed to duplicate page on server: #{error}"
      gotoPageId pageId

## Delete Pages tool: a dropdown menu below the button, then a confirmation
## dialog in the middle of the screen.  The menu has the four ways to delete,
## and Undo Delete and Redo Delete for this browser's history of deletions
## (see ../PageTrash.coffee), which are separate from the normal Undo/Redo.

[menu, setMenu] = createSignal null     # {left, top} while dropdown is open
[pending, setPending] = createSignal null  # what awaits confirmation:
  # {action: 'delete', ids, blank, kind, ...} or {action: 'undo'/'redo', id, ...}
  # plus `text` to ask, `label` of the confirm button, `danger` for its style

closeMenu = -> setMenu null
cancelDelete = -> setPending null

menuWidth = 256  # 16em; keep in sync with `.pageDelMenu` in main.styl

openMenu = ->
  button = document.querySelector '[data-tool="pageDel"]'
  return unless (rect = button?.getBoundingClientRect())?
  setMenu
    left: Math.max 8, Math.min rect.left, window.innerWidth - menuWidth - 8
    top: rect.bottom + 4

## Human-readable page numbers: "Page 3", "Pages 3 and 4", "Pages 3 to 7"
pageRange = (first, last) ->
  if first == last
    "Page #{first}"
  else if last == first + 1
    "Pages #{first} and #{last}"
  else
    "Pages #{first} to #{last}"

## The delete choices for the current page, with the pages each would delete.
deleteChoices = ->
  room = currentRoom()
  pages = room?.data()?.pages
  index = room?.pageIndex currentPage()
  return [] unless pages? and index?
  n = pages.length
  [
    kind: 'current'
    label: 'Delete Current Page'
    ids: [pages[index]]
    disabled: n <= 1
    note: "This is the only page. Can't be deleted."
    ask: "Delete Page #{index+1} for everyone?"
  ,
    kind: 'left'
    label: 'Delete All Pages to Left'
    ids: pages[...index]
    disabled: index <= 0
    note: 'No pages to the left.'
    ask: "Delete #{pageRange 1, index} for everyone?"
  ,
    kind: 'right'
    label: 'Delete All Pages to Right'
    ids: pages[index+1..]
    disabled: index >= n - 1
    note: 'No pages to the right.'
    ask: "Delete #{pageRange index+2, n} for everyone?"
  ,
    kind: 'all'
    label: 'Delete All Pages'
    ids: pages
    blank: true  # leave a new blank page
    ask:
      if n == 1
        "Delete Page 1 and leave a blank page?"
      else
        "Delete all #{n} pages and leave one blank page?"
  ]

## Delete choice icons: a trash can with a small overlay at its bottom right
## (a page, or "All") and, for left/right, a curved arrow at its top left/right.
## All four share the same trash can position, so they have the same footprint.
DeleteIcon = (props) ->
  <svg class="delIcon" viewBox="0 1 29 29" aria-hidden="true">
    <path class="base" d={trashPath}
     transform="translate(3.2 7.4) scale(0.042)"/>
    {switch props.kind
      when 'all'
        <>
          <text class="halo" x="15.6" y="28.9" textLength="11.8" lengthAdjust="spacingAndGlyphs">All</text>
          <text class="txt" x="15.6" y="28.9" textLength="11.8" lengthAdjust="spacingAndGlyphs">All</text>
        </>
      else
        <>
          <path class="halo" d="M16.8 15.6H23.8L27.2 19V28.9H16.8z"/>
          <path class="sheet" d="M16.8 15.6H23.8L27.2 19V28.9H16.8z"/>
          <path class="line" d="M23.8 15.6V19H27.2"/>
          {if props.kind == 'left'
            <>
              <path class="halo" d="M11.2 13.2C11.2 8.6 9.4 5.6 6.2 5.6"/>
              <path class="halo fill" d="M1.2 5.6L6.6 2.2V9z"/>
              <path class="arc" d="M11.2 13.2C11.2 8.6 9.4 5.6 6.2 5.6"/>
              <path class="head" d="M1.2 5.6L6.6 2.2V9z"/>
            </>
          else if props.kind == 'right'
            <>
              <path class="halo" d="M16.8 13.2C16.8 8.6 18.6 5.6 21.8 5.6"/>
              <path class="halo fill" d="M27.2 5.6L21.8 2.2V9z"/>
              <path class="arc" d="M16.8 13.2C16.8 8.6 18.6 5.6 21.8 5.6"/>
              <path class="head" d="M27.2 5.6L21.8 2.2V9z"/>
            </>
          }
        </>
    }
  </svg>

## After a press on the board that only closed the menu, ignore its release too,
## so that tools like Text don't act on a release without a press.
swallowRelease = (pointerId) ->
  done = (e) ->
    return unless e.pointerId == pointerId
    document.removeEventListener 'pointerup', done, true
    document.removeEventListener 'pointercancel', done, true
    e.stopPropagation()
  document.addEventListener 'pointerup', done, true
  document.addEventListener 'pointercancel', done, true
  return

## Don't let clicks inside our popups reach the toolbar button, because Solid
## sends events from <Portal>s on to the parent, where they'd toggle the menu.
stop = (e) -> e.stopPropagation()

DeleteOverlays = ->
  ## Close everything when the page changes, or when the tool goes away.
  createEffect on_ currentPageId, ->
    closeMenu()
    cancelDelete()
  , defer: true
  onCleanup ->
    closeMenu()
    cancelDelete()

  ## While a popup is open, close on outside click or Escape, and keep the
  ## board's hotkeys (e.g. Delete or Ctrl-Z) from acting behind it.
  createEffect ->
    return unless menu() or pending()
    onPointerDown = (e) ->
      return unless menu()
      return if e.target?.closest? '.pageDelMenu, [data-tool="pageDel"]'
      closeMenu()
      ## Dismissing the menu by clicking on the board shouldn't also draw.
      if e.target?.closest? '.board'
        e.preventDefault()
        e.stopPropagation()
        swallowRelease e.pointerId
    ## Keys pressed while a popup is open belong to it, so the board never sees
    ## them.  Key releases are not blocked: the board only uses one to end a
    ## Space pan that began earlier, and it ignores any other.  Blocking them
    ## would leave the Pan tool stuck when Space is released with a popup open,
    ## because holding Space keeps sending repeated key presses to the popup.
    onKeyDown = (e) ->
      e.stopPropagation()
      switch e.key
        when 'Escape'
          e.preventDefault()
          if pending() then cancelDelete() else closeMenu()
        when 'ArrowDown', 'ArrowUp'
          return unless menu()
          e.preventDefault()
          items = Array.from document.querySelectorAll '.pageDelOption:not(:disabled), .pageDelHist:not(:disabled)'
          return unless items.length
          step = if e.key == 'ArrowDown' then 1 else -1
          current = items.indexOf document.activeElement
          next =
            if current < 0
              if step > 0 then 0 else items.length - 1
            else
              (current + step + items.length) % items.length
          items[next].focus()
    document.addEventListener 'pointerdown', onPointerDown, true
    window.addEventListener 'keydown', onKeyDown, true
    window.addEventListener 'resize', closeMenu
    onCleanup ->
      document.removeEventListener 'pointerdown', onPointerDown, true
      window.removeEventListener 'keydown', onKeyDown, true
      window.removeEventListener 'resize', closeMenu

  ## What the Undo Delete and Redo Delete buttons would do now
  hist = createTracker -> historyInfo()

  choose = (choice) -> (e) ->
    e.stopPropagation()
    return if choice.disabled
    closeMenu()
    setPending
      action: 'delete'
      ids: choice.ids
      blank: choice.blank
      kind: choice.kind
      text: "#{choice.ask} You can reverse this with Undo Delete."
      label: 'Delete'
      danger: true
  chooseHist = (action) -> (e) ->
    e.stopPropagation()
    return unless (info = hist()[action])?
    closeMenu()
    setPending
      action: action
      id: info.id
      text: info.ask
      label: if action == 'undo' then 'Undo Delete' else 'Redo Delete'
      danger: action == 'redo'
  confirm = (e) ->
    e.stopPropagation()
    choice = pending()
    cancelDelete()
    return unless choice?
    switch choice.action
      when 'undo'
        undoDelete choice.id
      when 'redo'
        redoDelete choice.id
      else
        deletePages choice.ids, blank: choice.blank, kind: choice.kind
  cancel = (e) ->
    e.stopPropagation()
    cancelDelete()
  focusLater = (el) -> setTimeout (-> el.focus()), 0

  <>
    <Show when={menu()}>
      <Portal>
        <div class="pageDelMenu" role="menu" onClick={stop}
         style={left: "#{menu()?.left}px", top: "#{menu()?.top}px"}>
          <For each={deleteChoices()}>{(choice) ->
            <button type="button" class="pageDelOption" role="menuitem"
             disabled={choice.disabled} onClick={choose choice}>
              <DeleteIcon kind={choice.kind}/>
              <span>
                {choice.label}
                <Show when={choice.disabled}>
                  <small>{choice.note}</small>
                </Show>
              </span>
            </button>
          }</For>
          <div class="pageDelHistory">
            <button type="button" class="pageDelHist" role="menuitem"
             disabled={!hist().undo} onClick={chooseHist 'undo'}
             title={hist().undo?.ask ? 'No deletions to undo'}>
              <Icon class="histIcon" icon="undo" fill="currentColor"/>
              <span>Undo Delete</span>
            </button>
            <button type="button" class="pageDelHist" role="menuitem"
             disabled={!hist().redo} onClick={chooseHist 'redo'}
             title={hist().redo?.ask ? 'No deletions to redo'}>
              <Icon class="histIcon" icon="redo" fill="currentColor"/>
              <span>Redo Delete</span>
            </button>
          </div>
        </div>
      </Portal>
    </Show>
    <Show when={pending()}>
      <Portal>
        <div class="pageDelVeil" onClick={cancel}>
          <div class="pageDelDialog" role="alertdialog" onClick={stop}>
            <p>{pending()?.text}</p>
            <div class="pageDelButtons">
              <button type="button" ref={focusLater} onClick={cancel}>
                Cancel
              </button>
              <button type="button" classList={danger: pending()?.danger}
               onClick={confirm}>
                {pending()?.label}
              </button>
            </div>
          </div>
        </div>
      </Portal>
    </Show>
  </>

defineTool
  name: 'pageDel'
  category: 'page'
  icon: 'trash-alt'
  help: 'Delete pages: current, left, right, or all. Undo Delete and Redo Delete are in this menu'
  active: -> menu()?
  click: ->
    if menu()
      closeMenu()
    else
      cancelDelete()
      openMenu()
  portal: -> <DeleteOverlays/>
