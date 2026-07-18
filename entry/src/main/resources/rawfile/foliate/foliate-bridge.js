import './view.js'

if (!Promise.withResolvers) {
  Promise.withResolvers = () => {
    let resolve
    let reject
    const promise = new Promise((res, rej) => { resolve = res; reject = rej })
    return { promise, resolve, reject }
  }
}

if (!Object.groupBy) {
  Object.groupBy = (items, callback) => {
    const result = Object.create(null)
    let index = 0
    for (const item of items) {
      const key = callback(item, index++)
      ;(result[key] ||= []).push(item)
    }
    return result
  }
}

const queue = []
const viewer = document.querySelector('#viewer')
const loading = document.querySelector('#loading')
let view = null
let currentStyle = {}
let zoneActions = [1, 1, 1, 3, 3, 3, 2, 2, 2]
let lastHandledTapAt = 0
let turnBusy = false
let livePageFrame = 0
let lastLivePageKey = ''
let currentFormat = ''
let lastLocationCfi = ''
let openSequence = 0

const ACTION_NONE = -1
const ACTION_MENU = 0
const ACTION_NEXT_PAGE = 1
const ACTION_PREV_PAGE = 2
const BOOK_FONT_FAMILY = '__book__'
const ANIM_NONE = 0
const ANIM_SLIDE = 1
const ANIM_COVER = 2
const ANIM_SIMULATION = 3
const ANIM_SCROLL = 4

const emit = (type, data = {}) => queue.push({ type, data })
const errorText = error => error?.message || String(error || '未知错误')
const params = new URLSearchParams(location.search)

class RemoteFile {
  constructor(url, size) {
    this.url = new URL(url, location.href).href
    this.size = size
    this.name = decodeURIComponent(new URL(this.url).pathname.split('/').pop() || 'book.mobi')
    this.type = 'application/x-mobipocket-ebook'
  }
  static async open(url) {
    const absolute = new URL(url, location.href).href
    const response = await fetch(absolute, { method: 'HEAD' })
    if (!response.ok) throw new Error(`读取书籍失败：HTTP ${response.status}`)
    const size = Number(response.headers.get('content-length') || 0)
    if (!size) throw new Error('读取书籍失败：无法获取文件大小')
    return new RemoteFile(absolute, size)
  }
  slice(start = 0, end = this.size) {
    const from = Math.max(0, Number(start) || 0)
    const to = Math.max(from, Math.min(this.size, end == null ? this.size : Number(end)))
    const url = this.url
    return {
      size: to - from,
      arrayBuffer: async () => {
        if (to <= from) return new ArrayBuffer(0)
        const response = await fetch(url, { headers: { Range: `bytes=${from}-${to - 1}` } })
        if (!response.ok && response.status !== 206)
          throw new Error(`读取书籍分段失败：HTTP ${response.status}`)
        return response.arrayBuffer()
      }
    }
  }
  async arrayBuffer() {
    return this.slice(0, this.size).arrayBuffer()
  }
}

const encodeBookPath = path => String(path || '').split('/')
  .filter(part => part.length > 0)
  .map(part => encodeURIComponent(part))
  .join('/')

const openEpubDirectory = async baseUrl => {
  const base = new URL(baseUrl || '/book/', location.href).href.replace(/\/?$/, '/')
  const resourceUrl = path => new URL(encodeBookPath(path), base).href
  const loadText = async path => {
    const response = await fetch(resourceUrl(path))
    return response.ok ? response.text() : null
  }
  const loadBlob = async path => {
    const response = await fetch(resourceUrl(path))
    return response.ok ? response.blob() : null
  }
  const { EPUB } = await import('./epub.js')
  // Section sizes are only used for whole-book progress estimation. Returning
  // an equal non-zero weight keeps navigation valid without prefetching every
  // extracted EPUB resource just to issue HEAD requests.
  return new EPUB({ loadText, loadBlob, getSize: () => 1 }).init()
}

const flattenTOC = (items, level = 0, result = []) => {
  for (const item of items || []) {
    result.push({ label: item.label || '', href: item.href || '', level })
    flattenTOC(item.subitems, level + 1, result)
  }
  return result
}

const languageValue = value => {
  if (!value) return ''
  if (typeof value === 'string') return value
  return value['zh-CN'] || value.zh || value.en || Object.values(value)[0] || ''
}

const contributorValue = value => {
  if (Array.isArray(value)) return value.map(contributorValue).filter(Boolean).join('、')
  if (typeof value === 'string') return value
  return languageValue(value?.name ?? value)
}

const textFromNode = node => {
  if (!node) return ''
  const clone = node.cloneNode(true)
  clone.querySelectorAll?.('script,style,noscript,svg')?.forEach(element => element.remove())
  clone.querySelectorAll?.('br,p,div,section,article,header,footer,h1,h2,h3,h4,h5,h6,li,blockquote,tr')
    ?.forEach(element => element.append('\n'))
  return String(clone.textContent || '')
    .replace(/\r/g, '')
    .replace(/[ \t\u00a0]+/g, ' ')
    .replace(/ *\n */g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim()
}

const cssValue = (value, fallback) => value === undefined || value === null || value === '' ? fallback : value
const cssString = value => `'${String(value || '').replace(/\\/g, '\\\\').replace(/'/g, "\\'")}'`
const cssUrl = value => String(value || '').replace(/\\/g, '\\\\').replace(/'/g, "\\'")
const cssFontFamily = value => {
  const family = String(cssValue(value, 'HarmonyOS Sans'))
  return family === 'serif' || family === 'monospace' || family === 'sans-serif'
    ? family : `${cssString(family)}, sans-serif`
}

const currentStyleValues = () => {
  const family = cssValue(currentStyle.fontFamily, BOOK_FONT_FAMILY)
  const useBookFont = family === BOOK_FONT_FAMILY
  return {
    animType: Number(cssValue(currentStyle.animType, ANIM_NONE)),
    flowMode: cssValue(currentStyle.flowMode, 'paginated'),
    bg: cssValue(currentStyle.backgroundColor, '#F5F0E8'),
    color: cssValue(currentStyle.color, '#333333'),
    fontSize: Number(cssValue(currentStyle.fontSize, 18)),
    family, useBookFont, familyCss: useBookFont ? '' : cssFontFamily(family),
    weight: cssValue(currentStyle.fontWeight, '400'),
    lineHeight: Number(cssValue(currentStyle.lineHeight, 1.6)),
    letterSpacing: Number(cssValue(currentStyle.letterSpacing, 0)),
    paraSpacing: Number(cssValue(currentStyle.paragraphSpacing, 10)),
    indent: Number(cssValue(currentStyle.indentSize, 2)),
    pt: Number(cssValue(currentStyle.paddingTop, 24)),
    pb: Number(cssValue(currentStyle.paddingBottom, 24)),
    pl: Number(cssValue(currentStyle.paddingLeft, 20)),
    pr: Number(cssValue(currentStyle.paddingRight, 20)),
    textAlign: cssValue(currentStyle.textAlign, 'justify')
  }
}

const fontFaceCss = () => {
  if (currentStyle.fontFamily === BOOK_FONT_FAMILY) return ''
  return (Array.isArray(currentStyle.fontFaces) ? currentStyle.fontFaces : [])
    .filter(face => face?.familyName && face?.url)
    .map(face => `@font-face{font-family:${cssString(face.familyName)};src:url('${cssUrl(face.url)}');font-display:swap;}`)
    .join('')
}

const currentChineseMode = () => {
  const mode = cssValue(currentStyle.chineseMode, 'original')
  return mode === 'simplified' || mode === 'traditional' ? mode : 'original'
}

const applyChineseConversion = doc => {
  if (!doc?.body) return
  try { window.LegadoChineseConverter?.convertDocument?.(doc, currentChineseMode()) }
  catch (error) { emit('debug', { message: `chinese conversion failed: ${errorText(error)}` }) }
}

const resolveChapterTarget = async href => {
  if (!href || !view?.book?.resolveHref) return null
  try { return await view.book.resolveHref(href) }
  catch (_) { return null }
}

const getChapterText = async (href, nextHref) => {
  const book = view?.book
  if (!book) return ''
  const resolved = await resolveChapterTarget(href)
  if (!resolved) {
    const content = view?.renderer?.getContents?.()?.[0]
    return textFromNode(content?.doc?.body)
  }
  const section = book.sections?.[resolved.index]
  if (!section?.createDocument) return ''
  const doc = await section.createDocument()
  applyChineseConversion(doc)
  const body = doc.body || doc.documentElement
  if (!body) return ''
  const start = typeof resolved.anchor === 'function' ? resolved.anchor(doc) : null
  let end = null
  if (nextHref) {
    const next = await resolveChapterTarget(nextHref)
    if (next?.index === resolved.index && typeof next.anchor === 'function') end = next.anchor(doc)
  }
  if (!start || !body.contains(start)) return textFromNode(body)
  try {
    const range = doc.createRange()
    range.selectNodeContents(body)
    range.setStartAfter(start)
    if (end && body.contains(end)) range.setEndBefore(end)
    return textFromNode(range.cloneContents())
  } catch (_) {
    return textFromNode(body)
  }
}

const applyDocumentStyle = doc => {
  if (!doc?.documentElement) return
  let style = doc.querySelector('#legado-publication-style')
  if (!style) {
    style = doc.createElement('style')
    style.id = 'legado-publication-style'
    ;(doc.head || doc.documentElement).append(style)
  }
  const v = currentStyleValues()
  const bodyFontCss = v.useBookFont ? '' : `font-family:${v.familyCss} !important;`
  const bodyAllFontCss = v.useBookFont ? '' : `font-family:${v.familyCss} !important;`
  style.textContent = fontFaceCss() +
    `html,body{background:${v.bg} !important;color:${v.color} !important;` +
    `height:100% !important;min-height:100% !important;}` +
    `body{${bodyFontCss}font-size:${v.fontSize}px !important;font-weight:${v.weight} !important;` +
    `line-height:${v.lineHeight} !important;letter-spacing:${v.letterSpacing}px !important;` +
    `text-align:${v.textAlign} !important;box-sizing:border-box !important;` +
    `padding:0 !important;}` +
    `body *{${bodyAllFontCss}box-sizing:border-box !important;font-weight:${v.weight} !important;` +
    `letter-spacing:${v.letterSpacing}px !important;}` +
    `p,div,li,blockquote,td,th{line-height:${v.lineHeight} !important;}` +
    `p{margin-top:0 !important;margin-bottom:${v.paraSpacing}px !important;text-indent:${v.indent}em !important;` +
    `font-weight:${v.weight} !important;letter-spacing:${v.letterSpacing}px !important;}` +
    `img,svg{max-width:100% !important;max-height:85vh !important;object-fit:contain !important;` +
    `page-break-inside:avoid !important;break-inside:avoid !important;}` +
    `table{max-width:100% !important;}a{color:inherit !important;}`
  doc.documentElement.style.backgroundColor = v.bg
  if (doc.body) {
    doc.body.style.backgroundColor = v.bg
    doc.body.style.color = v.color
    if (v.useBookFont) doc.body.style.removeProperty('font-family')
    else doc.body.style.fontFamily = v.familyCss
    doc.body.style.fontSize = `${v.fontSize}px`
    doc.body.style.fontWeight = v.weight
    doc.body.style.lineHeight = String(v.lineHeight)
    doc.body.style.letterSpacing = `${v.letterSpacing}px`
    doc.body.style.boxSizing = 'border-box'
    doc.body.style.paddingTop = '0px'
    doc.body.style.paddingBottom = '0px'
    doc.body.style.paddingLeft = '0px'
    doc.body.style.paddingRight = '0px'
  }
  applyChineseConversion(doc)
  bindTap(doc)
}

const applyStyle = () => {
  const v = currentStyleValues()
  document.documentElement.style.backgroundColor = v.bg
  document.body.style.backgroundColor = v.bg
  viewer.style.backgroundColor = v.bg
  const fitPdfWidth = currentFormat === 'pdf' && view?.isFixedLayout
  viewer.style.paddingLeft = fitPdfWidth ? '0px' : `${v.pl}px`
  viewer.style.paddingRight = fitPdfWidth ? '0px' : `${v.pr}px`
  viewer.style.boxSizing = 'border-box'
  if (!view?.renderer) return
  if (fitPdfWidth) view.renderer.setAttribute('zoom', 'fit-width')
  if (v.flowMode === 'scrolled' || v.animType === ANIM_SCROLL) view.renderer.setAttribute('flow', 'scrolled')
  else view.renderer.removeAttribute('flow')
  view.renderer.setAttribute('margin', '0px')
  view.renderer.setAttribute('margin-top', `${Math.max(0, v.pt)}px`)
  view.renderer.setAttribute('margin-bottom', `${Math.max(0, v.pb)}px`)
  view.renderer.setAttribute('gap', '0%')
  for (const item of view.renderer.getContents?.() || []) applyDocumentStyle(item.doc)
  requestAnimationFrame(() => view?.renderer?.render?.())
}

const currentSectionPages = () => {
  const renderer = view?.renderer
  if (view?.isFixedLayout) return { page: 1, total: 1 }
  if (renderer?.getAttribute?.('flow') === 'scrolled') {
    const total = Math.max(1, Number(renderer.pages || 1))
    const page = Math.max(1, Math.min(total, Number(renderer.page || 0) + 1))
    return { page, total }
  }
  const bufferedPages = Number(renderer?.pages || 0)
  if (!renderer || bufferedPages <= 2) return { page: 0, total: 0 }
  const total = Math.max(1, bufferedPages - 2)
  const page = Math.max(1, Math.min(total, Number(renderer.page || 1)))
  return { page, total }
}

const emitLivePage = () => {
  // PDF 页脚表示 PDF 文档页（如 19/480），不能被当前 HTML/画布内部
  // 的屏幕分页（如 2/2）覆盖。PDF 页码统一由 relocate/location 上报。
  if (currentFormat === 'pdf' || !isScrollMode() || livePageFrame) return
  livePageFrame = requestAnimationFrame(() => {
    livePageFrame = 0
    const sectionPages = currentSectionPages()
    const key = `${sectionPages.page}/${sectionPages.total}`
    if (key === lastLivePageKey) return
    lastLivePageKey = key
    emit('page', { page: sectionPages.page, totalPages: sectionPages.total })
  })
}

const frameViewportSize = () => {
  const rect = viewer?.getBoundingClientRect?.()
  if (rect?.width > 0 && rect?.height > 0)
    return { width: rect.width, height: rect.height }
  const viewport = window.visualViewport
  return {
    width: viewport?.width || window.innerWidth || document.documentElement.clientWidth || 1,
    height: viewport?.height || window.innerHeight || document.documentElement.clientHeight || 1
  }
}

const parseCssPx = value => {
  const parsed = parseFloat(value)
  return Number.isFinite(parsed) ? parsed : 0
}

const pagedColumnGap = doc => {
  for (const element of [doc?.body, doc?.documentElement]) {
    if (!element) continue
    try {
      const style = doc.defaultView.getComputedStyle(element)
      const gap = parseCssPx(style.columnGap || style.webkitColumnGap)
      if (gap > 0) return gap
    } catch (_) {}
  }
  return 0
}

const normalizeIframeAxis = (value, width, doc) => {
  if (!Number.isFinite(value) || !Number.isFinite(width) || width <= 0) return value
  if (value >= 0 && value <= width) return value
  try {
    const childView = doc?.defaultView
    const offset = childView?.visualViewport?.pageLeft || childView?.scrollX || childView?.pageXOffset || 0
    const candidate = value - offset
    if (candidate >= 0 && candidate <= width) return candidate
  } catch (_) {}
  let pitch = width + pagedColumnGap(doc)
  if (!Number.isFinite(pitch) || pitch <= 0) pitch = width
  let normalized = value % pitch
  if (normalized < 0) normalized += pitch
  return Math.min(normalized, width)
}

const parentViewportPoint = (x, y, doc) => {
  if (!doc || doc === document || !doc.defaultView) return { x, y }
  try {
    const frame = doc.defaultView.frameElement
    const rect = frame?.getBoundingClientRect?.()
    if (rect) return {
      x: rect.left + normalizeIframeAxis(x, rect.width || frameViewportSize().width, doc),
      y: rect.top + Math.max(0, Math.min(rect.height || frameViewportSize().height, y))
    }
  } catch (_) {}
  return { x, y }
}

const zoneFromPoint = (x, y, doc) => {
  const size = frameViewportSize()
  const point = parentViewportPoint(x, y, doc)
  const screenX = Math.max(0, Math.min(size.width, point.x))
  const screenY = Math.max(0, Math.min(size.height, point.y))
  const col = screenX < size.width / 3 ? 0 : (screenX > size.width * 2 / 3 ? 2 : 1)
  const row = screenY < size.height / 3 ? 0 : (screenY > size.height * 2 / 3 ? 2 : 1)
  return { zone: row * 3 + col, x: screenX, y: screenY, rawX: x, rawY: y,
    width: size.width, height: size.height }
}

const isInteractiveTarget = target => !!target?.closest?.('a,button,input,textarea,select,label,[contenteditable="true"]')

const hasSelection = doc => {
  try { return !!String(doc?.getSelection?.()?.toString() || '').trim() }
  catch (_) { return false }
}

const finishTap = (x, y, doc, event) => {
  if (hasSelection(doc) || isInteractiveTarget(event?.target)) return
  const info = zoneFromPoint(x, y, doc)
  const action = Number(zoneActions[info.zone] ?? ACTION_NONE)
  event?.preventDefault?.()
  event?.stopPropagation?.()
  event?.stopImmediatePropagation?.()
  if (action === ACTION_NEXT_PAGE) window.nextPage()
  else if (action === ACTION_PREV_PAGE) window.prevPage()
  else if (action === ACTION_MENU) emit('menu', { zone: info.zone })
  else if (action !== ACTION_NONE) emit('tapAction', {
    zone: info.zone, action,
    x: Math.round(info.x), y: Math.round(info.y),
    rawX: Math.round(info.rawX), rawY: Math.round(info.rawY),
    width: Math.round(info.width), height: Math.round(info.height)
  })
  lastHandledTapAt = Date.now()
}

const stopGestureEvent = (event, preventDefault = false) => {
  if (!event) return
  if (preventDefault) event.preventDefault?.()
  event.stopPropagation?.()
  event.stopImmediatePropagation?.()
}

const finishSwipe = (start, touch, doc, event) => {
  const dx = touch.clientX - start.x
  const dy = touch.clientY - start.y
  const absX = Math.abs(dx)
  const absY = Math.abs(dy)
  const duration = Date.now() - start.time
  const minDistance = Math.max(40, frameViewportSize().width * 0.08)
  const isHorizontalSwipe = absX >= minDistance && absX > absY * 1.25 && duration <= 1200
  stopGestureEvent(event, isHorizontalSwipe)
  lastHandledTapAt = Date.now()
  if (!isHorizontalSwipe || hasSelection(doc)) return false
  if (dx > 0) window.prevPage()
  else window.nextPage()
  return true
}

const isScrollMode = () => cssValue(currentStyle.flowMode, 'paginated') === 'scrolled' ||
  Number(cssValue(currentStyle.animType, ANIM_NONE)) === ANIM_SCROLL

function bindTap(doc) {
  if (!doc || doc.__legadoTapBound) return
  doc.__legadoTapBound = true
  let touchStart = null
  let linkTouchStart = null
  doc.addEventListener('touchstart', event => {
    const link = event.target?.closest?.('a[href]')
    if (link && event.touches?.length === 1) {
      const touch = event.touches[0]
      linkTouchStart = { link, x: touch.clientX, y: touch.clientY, time: Date.now() }
      touchStart = null
      return
    }
    linkTouchStart = null
    if (isInteractiveTarget(event.target) || !event.touches || event.touches.length !== 1) {
      touchStart = null
      return
    }
    const touch = event.touches[0]
    touchStart = { x: touch.clientX, y: touch.clientY, time: Date.now() }
    // The bridge owns the whole gesture so foliate's paginator cannot snap a
    // second time after we explicitly turn the page on touchend.
    if (!isScrollMode()) stopGestureEvent(event)
  }, { capture: true, passive: true })
  doc.addEventListener('touchmove', event => {
    if (linkTouchStart) {
      const touch = event.touches?.[0]
      if (!touch || Math.abs(touch.clientX - linkTouchStart.x) > 18 ||
        Math.abs(touch.clientY - linkTouchStart.y) > 18) linkTouchStart = null
      return
    }
    if (!touchStart) return
    if (isScrollMode()) return
    const touch = event.touches?.[0]
    if (!touch) return
    const dx = Math.abs(touch.clientX - touchStart.x)
    const dy = Math.abs(touch.clientY - touchStart.y)
    stopGestureEvent(event, dx > 12 && dx > dy)
  }, { capture: true, passive: false })
  doc.addEventListener('touchend', event => {
    if (linkTouchStart) {
      const start = linkTouchStart
      linkTouchStart = null
      const touch = event.changedTouches?.[0]
      if (touch && Math.abs(touch.clientX - start.x) <= 18 &&
        Math.abs(touch.clientY - start.y) <= 18 && Date.now() - start.time <= 550) {
        event.preventDefault?.()
        start.link.click()
      }
      return
    }
    if (!touchStart || !event.changedTouches || event.changedTouches.length < 1) return
    const touch = event.changedTouches[0]
    const dx = Math.abs(touch.clientX - touchStart.x)
    const dy = Math.abs(touch.clientY - touchStart.y)
    const duration = Date.now() - touchStart.time
    const start = touchStart
    touchStart = null
    if (isScrollMode()) {
      if (dx <= 18 && dy <= 18 && duration <= 550) finishTap(touch.clientX, touch.clientY, doc, event)
      return
    }
    if (finishSwipe(start, touch, doc, event)) return
    if (dx > 18 || dy > 18 || duration > 550) return
    finishTap(touch.clientX, touch.clientY, doc, event)
  }, { capture: true, passive: false })
  doc.addEventListener('touchcancel', event => {
    linkTouchStart = null
    if (!touchStart) return
    touchStart = null
    stopGestureEvent(event)
  }, { capture: true, passive: false })
  doc.addEventListener('click', event => {
    if (Date.now() - lastHandledTapAt < 450) return
    finishTap(event.clientX, event.clientY, doc, event)
  }, true)
}

const openBook = async (bookUrl, target, format) => {
  const sequence = ++openSequence
  try {
    currentFormat = format
    loading.style.display = 'flex'
    if (view) {
      view.close?.()
      view.book?.destroy?.()
      view.remove()
    }
    view = document.createElement('foliate-view')
    viewer.append(view)
    view.addEventListener('load', event => applyDocumentStyle(event.detail?.doc))
    view.addEventListener('relocate', event => {
      const loc = event.detail || {}
      lastLocationCfi = loc.cfi || ''
      const sectionPages = currentFormat === 'pdf' ? {
        page: Number(loc.section?.current ?? 0) + 1,
        total: Number(loc.section?.total ?? view?.book?.sections?.length ?? 0)
      } : currentSectionPages()
      emit('location', {
        cfi: loc.cfi || '', href: loc.tocItem?.href || '',
        chapterIndex: Number(loc.section?.current ?? loc.index ?? loc.location?.current ?? 0),
        page: sectionPages.page,
        totalPages: sectionPages.total,
        percentage: Number(loc.fraction ?? 0)
      })
    })
    let publication
    if (format === 'epub-dir') publication = await openEpubDirectory(bookUrl)
    else {
      const remoteFile = await RemoteFile.open(bookUrl)
      if (format === 'pdf') {
        const { makePDF } = await import('./pdf.js')
        publication = await makePDF(remoteFile, { reflow: currentStyle.pdfMode === 'reflow' })
      } else publication = remoteFile
    }
    if (sequence !== openSequence) {
      publication?.destroy?.()
      return
    }
    await view.open(publication)
    view.renderer?.addEventListener?.('scroll', emitLivePage)
    const book = view.book
    if (format !== 'epub-dir' && Number(book?.mobi?.headers?.palmdoc?.encryption || 0) !== 0)
      throw new Error('暂不支持 DRM 加密的 Kindle 书籍')
    const metadata = book?.metadata || {}
    emit('metadata', {
      title: languageValue(metadata.title),
      author: contributorValue(metadata.author),
      description: languageValue(metadata.description),
      pageCount: Number(book?.sections?.length || 0),
      pdfReflowAvailable: book?.pdfReflowAvailable,
      pdfMode: book?.pdfMode
    })
    emit('toc', flattenTOC(book?.toc))
    applyStyle()
    if (target) await view.goTo(target)
    else await view.init({ showTextStart: true })
    loading.style.display = 'none'
    emit('ready')
  } catch (error) {
    loading.style.display = 'none'
    emit('error', { message: errorText(error) })
  }
}

const playTurnAnimation = async (direction, navigate) => {
  if (!view?.renderer || turnBusy) return
  const renderer = view.renderer
  const mode = Number(cssValue(currentStyle.animType, ANIM_NONE))
  turnBusy = true
  try {
    if (isScrollMode()) {
      const distance = Math.max(120, frameViewportSize().height * 0.88)
      await (direction > 0 ? view.next(distance) : view.prev(distance))
      return
    }
    if (mode === ANIM_NONE || !renderer.animate) {
      await navigate()
      return
    }
    const sign = direction > 0 ? 1 : -1
    if (mode === ANIM_COVER) {
      await navigate()
      await renderer.animate([
        { transform: `translateX(${sign * 100}%)`, boxShadow: `${-sign * 12}px 0 24px rgba(0,0,0,.28)` },
        { transform: 'translateX(0)', boxShadow: '0 0 0 rgba(0,0,0,0)' }
      ], { duration: 280, easing: 'cubic-bezier(.2,.75,.2,1)' }).finished
      return
    }
    if (mode === ANIM_SIMULATION) {
      renderer.style.transformOrigin = direction > 0 ? 'left center' : 'right center'
      await renderer.animate([
        { transform: 'perspective(1200px) rotateY(0deg)', filter: 'brightness(1)' },
        { transform: `perspective(1200px) rotateY(${sign * -18}deg)`, filter: 'brightness(.72)' }
      ], { duration: 150, easing: 'ease-in' }).finished
      await navigate()
      await renderer.animate([
        { transform: `perspective(1200px) rotateY(${sign * 18}deg)`, filter: 'brightness(.72)' },
        { transform: 'perspective(1200px) rotateY(0deg)', filter: 'brightness(1)' }
      ], { duration: 190, easing: 'ease-out' }).finished
      renderer.style.transformOrigin = ''
      return
    }
    await renderer.animate([
      { transform: 'translateX(0)', opacity: 1 },
      { transform: `translateX(${sign * -16}%)`, opacity: .72 }
    ], { duration: 120, easing: 'ease-in' }).finished
    await navigate()
    await renderer.animate([
      { transform: `translateX(${sign * 18}%)`, opacity: .72 },
      { transform: 'translateX(0)', opacity: 1 }
    ], { duration: 180, easing: 'ease-out' }).finished
  } catch (error) {
    emit('debug', { message: `page animation failed: ${errorText(error)}` })
  } finally {
    turnBusy = false
  }
}

window.nextPage = () => playTurnAnimation(1, () => view?.goRight?.())
window.prevPage = () => playTurnAnimation(-1, () => view?.goLeft?.())
window.goTo = target => target ? view?.goTo?.(target) : null
window.goToHref = target => target ? view?.goTo?.(target) : null
window.setPdfMode = mode => {
  if (currentFormat !== 'pdf' || !bookUrl) return
  currentStyle.pdfMode = mode === 'reflow' ? 'reflow' : 'original'
  openBook(bookUrl, lastLocationCfi, 'pdf')
}
globalThis.LegadoPdfEnhance = () => ({
  autoCrop: currentStyle.pdfAutoCrop === true,
  darken: Number(currentStyle.pdfDarken || 0),
  whiten: Number(currentStyle.pdfWhiten || 0)
})
window.applyStyle = style => {
  try { currentStyle = typeof style === 'string' ? JSON.parse(style) : (style || {}) }
  catch (_) { currentStyle = {} }
  applyStyle()
  if (currentFormat === 'pdf') {
    for (const item of view?.renderer?.getContents?.() || []) item.doc?.__legadoPdfRefresh?.()
  }
}
window.setZoneActions = actions => {
  try { zoneActions = typeof actions === 'string' ? JSON.parse(actions) : actions }
  catch (_) {}
}
window.clearSelection = () => view?.deselect?.()
window.requestChapterText = async (requestId, href, nextHref) => {
  try {
    const text = await getChapterText(href, nextHref)
    emit('chapterText', { requestId, text })
  } catch (error) {
    emit('chapterText', { requestId, text: '', error: errorText(error) })
  }
}
window.pollEvent = () => queue.length ? JSON.stringify(queue.shift()) : 'null'
window.pollEvents = () => queue.length ? JSON.stringify(queue.splice(0)) : 'null'

window.applyStyle(params.get('style') || '{}')
window.setZoneActions(params.get('actions') || '[]')
const bookUrl = params.get('book')
if (bookUrl) openBook(bookUrl, params.get('target') || '', params.get('format') || '')
