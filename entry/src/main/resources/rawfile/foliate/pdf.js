const pdfjsPath = path => new URL(`vendor/pdfjs/${path}`, import.meta.url).toString()

import './vendor/pdfjs/pdf.mjs'
const pdfjsLib = globalThis.pdfjsLib
pdfjsLib.GlobalWorkerOptions.workerSrc = pdfjsPath('pdf.worker.mjs')

const fetchText = async url => await (await fetch(url)).text()

// https://raw.githubusercontent.com/mozilla/pdf.js/refs/tags/v5.5.207/web/text_layer_builder.css
const textLayerBuilderCSS = await fetchText(pdfjsPath('text_layer_builder.css'))

// https://raw.githubusercontent.com/mozilla/pdf.js/refs/tags/v5.5.207/web/annotation_layer_builder.css
const annotationLayerBuilderCSS = await fetchText(pdfjsPath('annotation_layer_builder.css'))

const clampByte = value => Math.max(0, Math.min(255, Math.round(value)))

const enhanceOptions = () => {
    const value = globalThis.LegadoPdfEnhance?.() ?? {}
    return {
        autoCrop: value.autoCrop === true,
        darken: Math.max(0, Math.min(100, Number(value.darken) || 0)),
        whiten: Math.max(0, Math.min(100, Number(value.whiten) || 0)),
    }
}

const detectContentRect = canvas => {
    const maxSide = 360
    const scale = Math.min(1, maxSide / Math.max(canvas.width, canvas.height))
    const width = Math.max(1, Math.round(canvas.width * scale))
    const height = Math.max(1, Math.round(canvas.height * scale))
    const sample = document.createElement('canvas')
    sample.width = width
    sample.height = height
    const context = sample.getContext('2d', { willReadFrequently: true })
    context.drawImage(canvas, 0, 0, width, height)
    const pixels = context.getImageData(0, 0, width, height).data
    const border = []
    const borderSize = Math.max(2, Math.round(Math.min(width, height) * 0.025))
    for (let y = 0; y < height; y += 2) for (let x = 0; x < width; x += 2) {
        if (x >= borderSize && x < width - borderSize && y >= borderSize && y < height - borderSize) continue
        const i = (y * width + x) * 4
        border.push(pixels[i] * .299 + pixels[i + 1] * .587 + pixels[i + 2] * .114)
    }
    border.sort((a, b) => a - b)
    const background = border[Math.floor(border.length * .72)] ?? 255
    const threshold = Math.max(80, Math.min(245, background - 14))
    let left = width, top = height, right = -1, bottom = -1, count = 0
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
        const i = (y * width + x) * 4
        const luminance = pixels[i] * .299 + pixels[i + 1] * .587 + pixels[i + 2] * .114
        if (luminance >= threshold) continue
        left = Math.min(left, x); right = Math.max(right, x)
        top = Math.min(top, y); bottom = Math.max(bottom, y)
        count++
    }
    if (right < left || bottom < top || count < width * height * .001) return null
    const pad = Math.max(2, Math.round(Math.min(width, height) * .018))
    left = Math.max(0, left - pad); top = Math.max(0, top - pad)
    right = Math.min(width - 1, right + pad); bottom = Math.min(height - 1, bottom + pad)
    if ((right - left + 1) * (bottom - top + 1) > width * height * .97) return null
    return {
        x: Math.round(left / scale), y: Math.round(top / scale),
        width: Math.max(1, Math.round((right - left + 1) / scale)),
        height: Math.max(1, Math.round((bottom - top + 1) / scale)),
    }
}

const cropCanvas = (canvas, rect) => {
    if (!rect) return canvas
    const output = document.createElement('canvas')
    output.width = canvas.width
    output.height = canvas.height
    const context = output.getContext('2d')
    context.fillStyle = '#fff'
    context.fillRect(0, 0, output.width, output.height)
    const scale = Math.min(output.width / rect.width, output.height / rect.height)
    const width = rect.width * scale
    const height = rect.height * scale
    context.drawImage(canvas, rect.x, rect.y, rect.width, rect.height,
        (output.width - width) / 2, (output.height - height) / 2, width, height)
    return output
}

const adjustCanvas = (canvas, darken, whiten) => {
    if (darken <= 0 && whiten <= 0) return canvas
    const context = canvas.getContext('2d', { willReadFrequently: true })
    const image = context.getImageData(0, 0, canvas.width, canvas.height)
    const pixels = image.data
    const contrast = 1 + darken / 100 * 1.35
    const whitenStrength = whiten / 100
    for (let i = 0; i < pixels.length; i += 4) {
        const luminance = pixels[i] * .299 + pixels[i + 1] * .587 + pixels[i + 2] * .114
        const backgroundWeight = Math.max(0, Math.min(1, (luminance - 72) / 183)) * whitenStrength
        for (let c = 0; c < 3; c++) {
            const lifted = pixels[i + c] + (255 - pixels[i + c]) * backgroundWeight
            pixels[i + c] = clampByte((lifted - 128) * contrast + 128)
        }
    }
    context.putImageData(image, 0, 0)
    return canvas
}

const render = async (page, doc, zoom) => {
    const renderToken = (doc.__legadoPdfRenderToken ?? 0) + 1
    doc.__legadoPdfRenderToken = renderToken
    doc.__legadoPdfRefresh = () => render(page, doc, zoom)
    const scale = zoom * devicePixelRatio
    doc.documentElement.style.transform = `scale(${1 / devicePixelRatio})`
    doc.documentElement.style.transformOrigin = 'top left'
    doc.documentElement.style.setProperty('--scale-factor', scale)
    const viewport = page.getViewport({ scale })

    // the canvas must be in the `PDFDocument`'s `ownerDocument`
    // (`globalThis.document` by default); that's where the fonts are loaded
    const canvas = document.createElement('canvas')
    canvas.height = viewport.height
    canvas.width = viewport.width
    const canvasContext = canvas.getContext('2d')
    await page.render({ canvasContext, viewport }).promise
    if (doc.__legadoPdfRenderToken !== renderToken) return
    const options = enhanceOptions()
    const cropped = options.autoCrop ? cropCanvas(canvas, detectContentRect(canvas)) : canvas
    const enhanced = adjustCanvas(cropped, options.darken, options.whiten)
    doc.querySelector('#canvas').replaceChildren(doc.adoptNode(enhanced))

    const container = doc.querySelector('.textLayer')
    container.style.display = options.autoCrop ? 'none' : ''
    const textLayer = new pdfjsLib.TextLayer({
        textContentSource: await page.streamTextContent(),
        container, viewport,
    })
    await textLayer.render()

    // hide "offscreen" canvases appended to docuemnt when rendering text layer
    // https://github.com/mozilla/pdf.js/blob/642b9a5ae67ef642b9a8808fd9efd447e8c350e2/web/pdf_viewer.css#L51-L58
    for (const canvas of document.querySelectorAll('.hiddenCanvasElement'))
        Object.assign(canvas.style, {
            position: 'absolute',
            top: '0',
            left: '0',
            width: '0',
            height: '0',
            display: 'none',
        })

    // fix text selection
    // https://github.com/mozilla/pdf.js/blob/642b9a5ae67ef642b9a8808fd9efd447e8c350e2/web/text_layer_builder.js#L105-L107
    const endOfContent = document.createElement('div')
    endOfContent.className = 'endOfContent'
    container.append(endOfContent)
    // TODO: this only works in Firefox; see https://github.com/mozilla/pdf.js/pull/17923
    container.onpointerdown = () => container.classList.add('selecting')
    container.onpointerup = () => container.classList.remove('selecting')

    const div = doc.querySelector('.annotationLayer')
    div.style.display = options.autoCrop ? 'none' : ''
    const linkService = {
        goToDestination: () => {},
        getDestinationHash: dest => JSON.stringify(dest),
        addLinkAttributes: (link, url) => link.href = url,
    }
    await new pdfjsLib.AnnotationLayer({ page, viewport, div, linkService })
        .render({ annotations: await page.getAnnotations() })
}

const renderPage = async (page, getImageBlob) => {
    const viewport = page.getViewport({ scale: 1 })
    if (getImageBlob) {
        const canvas = document.createElement('canvas')
        canvas.height = viewport.height
        canvas.width = viewport.width
        const canvasContext = canvas.getContext('2d')
        await page.render({ canvasContext, viewport }).promise
        return new Promise(resolve => canvas.toBlob(resolve))
    }
    const src = URL.createObjectURL(new Blob([`
        <!DOCTYPE html>
        <html lang="en">
        <meta charset="utf-8">
        <meta name="viewport" content="width=${viewport.width}, height=${viewport.height}">
        <style>
        html, body {
            margin: 0;
            padding: 0;
        }
        /*
        https://github.com/mozilla/pdf.js/commit/bd05b255fabfc313b194bfe9a17ccded4d90fb5a
        */
        :root {
          --user-unit: 1;
          --total-scale-factor: calc(var(--scale-factor) * var(--user-unit));
          --scale-round-x: 1px;
          --scale-round-y: 1px;
        }
        ${textLayerBuilderCSS}
        ${annotationLayerBuilderCSS}
        </style>
        <div id="canvas"></div>
        <div class="textLayer"></div>
        <div class="annotationLayer"></div>
    `], { type: 'text/html' }))
    const onZoom = ({ doc, scale }) => render(page, doc, scale)
    return { src, onZoom }
}

const makeTOCItem = item => ({
    label: item.title,
    href: JSON.stringify(item.dest),
    subitems: item.items.length ? item.items.map(makeTOCItem) : null,
})

export const makePDF = async file => {
    const transport = new pdfjsLib.PDFDataRangeTransport(file.size, [])
    transport.requestDataRange = (begin, end) => {
        file.slice(begin, end).arrayBuffer().then(chunk => {
            transport.onDataRange(begin, chunk)
        })
    }
    const pdf = await pdfjsLib.getDocument({
        range: transport,
        cMapUrl: pdfjsPath('cmaps/'),
        standardFontDataUrl: pdfjsPath('standard_fonts/'),
        isEvalSupported: false,
    }).promise

    const book = { rendition: { layout: 'pre-paginated' } }

    const { metadata, info } = await pdf.getMetadata() ?? {}
    // TODO: for better results, parse `metadata.getRaw()`
    book.metadata = {
        title: metadata?.get('dc:title') ?? info?.Title,
        author: metadata?.get('dc:creator') ?? info?.Author,
        contributor: metadata?.get('dc:contributor'),
        description: metadata?.get('dc:description') ?? info?.Subject,
        language: metadata?.get('dc:language'),
        publisher: metadata?.get('dc:publisher'),
        subject: metadata?.get('dc:subject'),
        identifier: metadata?.get('dc:identifier'),
        source: metadata?.get('dc:source'),
        rights: metadata?.get('dc:rights'),
    }

    const outline = await pdf.getOutline()
    book.toc = outline?.length ? outline.map(makeTOCItem) :
        Array.from({ length: pdf.numPages }, (_, i) => ({
            label: `第 ${i + 1} 页`, href: JSON.stringify(i), subitems: null,
        }))

    const cache = new Map()
    book.sections = Array.from({ length: pdf.numPages }).map((_, i) => ({
        id: i,
        load: async () => {
            const cached = cache.get(i)
            if (cached) return cached
            const url = await renderPage(await pdf.getPage(i + 1))
            cache.set(i, url)
            return url
        },
        size: 1000,
    }))
    book.isExternal = uri => /^\w+:/i.test(uri)
    book.resolveHref = async href => {
        const parsed = JSON.parse(href)
        if (typeof parsed === 'number') return { index: parsed }
        const dest = typeof parsed === 'string'
            ? await pdf.getDestination(parsed) : parsed
        const index = await pdf.getPageIndex(dest[0])
        return { index }
    }
    book.splitTOCHref = async href => {
        const parsed = JSON.parse(href)
        const dest = typeof parsed === 'string'
            ? await pdf.getDestination(parsed) : parsed
        const index = await pdf.getPageIndex(dest[0])
        return [index, null]
    }
    book.getTOCFragment = doc => doc.documentElement
    book.getCover = async () => renderPage(await pdf.getPage(1), true)
    book.destroy = () => pdf.destroy()
    return book
}
