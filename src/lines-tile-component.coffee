# FIXME: I have currently removed the possibility to split a token when it reaches the `MaxTokenLength`. This comment serves as a reminder to readd it when polishing the code.

_ = require 'underscore-plus'

HighlightsComponent = require './highlights-component'
TokenIterator = require './token-iterator'
CharacterIterator = require './character-iterator'
{HtmlBuilder, Tag} = require './html-builder'
AcceptFilter = {acceptNode: -> NodeFilter.FILTER_ACCEPT}
WrapperDiv = document.createElement('div')
TokenTextEscapeRegex = /[&"'<>]/g
MaxTokenLength = 20000

cloneObject = (object) ->
  clone = {}
  clone[key] = value for key, value of object
  clone

module.exports =
class LinesTileComponent
  constructor: ({@presenter, @id}) ->
    @htmlBuilder = new HtmlBuilder
    @tokenIterator = new TokenIterator
    @characterIterator = new CharacterIterator
    @measuredLines = new Set
    @lineNodesByLineId = {}
    @screenRowsByLineId = {}
    @lineIdsByScreenRow = {}
    @domNode = document.createElement("div")
    @domNode.classList.add("tile")
    @domNode.style.position = "absolute"
    @domNode.style.display = "block"

    @highlightsComponent = new HighlightsComponent
    @domNode.appendChild(@highlightsComponent.getDomNode())

  getDomNode: ->
    @domNode

  updateSync: (state) ->
    @newState = state
    unless @oldState
      @oldState = {tiles: {}}
      @oldState.tiles[@id] = {lines: {}}

    @newTileState = @newState.tiles[@id]
    @oldTileState = @oldState.tiles[@id]

    if @newState.backgroundColor isnt @oldState.backgroundColor
      @domNode.style.backgroundColor = @newState.backgroundColor
      @oldState.backgroundColor = @newState.backgroundColor

    if @newTileState.zIndex isnt @oldTileState.zIndex
      @domNode.style.zIndex = @newTileState.zIndex
      @oldTileState.zIndex = @newTileState.zIndex

    if @newTileState.display isnt @oldTileState.display
      @domNode.style.display = @newTileState.display
      @oldTileState.display = @newTileState.display

    if @newTileState.height isnt @oldTileState.height
      @domNode.style.height = @newTileState.height + 'px'
      @oldTileState.height = @newTileState.height

    if @newState.width isnt @oldState.width
      @domNode.style.width = @newState.width + 'px'
      @oldTileState.width = @newTileState.width

    if @newTileState.top isnt @oldTileState.top or @newTileState.left isnt @oldTileState.left
      @domNode.style['-webkit-transform'] = "translate3d(#{@newTileState.left}px, #{@newTileState.top}px, 0px)"
      @oldTileState.top = @newTileState.top
      @oldTileState.left = @newTileState.left

    @removeLineNodes() unless @oldState.indentGuidesVisible is @newState.indentGuidesVisible
    @updateLineNodes()

    @highlightsComponent.updateSync(@newTileState)

    @oldState.indentGuidesVisible = @newState.indentGuidesVisible

  removeLineNodes: ->
    @removeLineNode(id) for id of @oldTileState.lines
    return

  removeLineNode: (id) ->
    @lineNodesByLineId[id].remove()
    delete @lineNodesByLineId[id]
    delete @lineIdsByScreenRow[@screenRowsByLineId[id]]
    delete @screenRowsByLineId[id]
    delete @oldTileState.lines[id]

  updateLineNodes: ->
    for id of @oldTileState.lines
      unless @newTileState.lines.hasOwnProperty(id)
        @removeLineNode(id)

    newLineIds = null
    newLinesHTML = null

    for id, lineState of @newTileState.lines
      if @oldTileState.lines.hasOwnProperty(id)
        @updateLineNode(id)
      else
        newLineIds ?= []
        newLinesHTML ?= ""
        newLineIds.push(id)
        newLinesHTML += @buildLineHTML(id)
        @screenRowsByLineId[id] = lineState.screenRow
        @lineIdsByScreenRow[lineState.screenRow] = id
        @oldTileState.lines[id] = cloneObject(lineState)

    return unless newLineIds?

    WrapperDiv.innerHTML = newLinesHTML
    newLineNodes = _.toArray(WrapperDiv.children)
    for id, i in newLineIds
      lineNode = newLineNodes[i]
      @lineNodesByLineId[id] = lineNode
      @domNode.appendChild(lineNode)

    return

  buildLineHTML: (id) ->
    {width} = @newState
    {screenRow, tokens, text, top, lineEnding, fold, isSoftWrapped, indentLevel, decorationClasses} = @newTileState.lines[id]

    classes = ''
    if decorationClasses?
      for decorationClass in decorationClasses
        classes += decorationClass + ' '
    classes += 'line'

    lineHTML = "<div class=\"#{classes}\" style=\"position: absolute; top: #{top}px; width: #{width}px;\" data-screen-row=\"#{screenRow}\">"

    if text is ""
      lineHTML += @buildEmptyLineInnerHTML(id)
    else
      lineHTML += @buildLineInnerHTML(id)

    lineHTML += '<span class="fold-marker"></span>' if fold
    lineHTML += "</div>"
    lineHTML

  buildEmptyLineInnerHTML: (id) ->
    {indentGuidesVisible} = @newState
    {indentLevel, tabLength, endOfLineInvisibles} = @newTileState.lines[id]

    if indentGuidesVisible and indentLevel > 0
      invisibleIndex = 0
      lineHTML = ''
      for i in [0...indentLevel]
        lineHTML += "<span class='indent-guide'>"
        for j in [0...tabLength]
          if invisible = endOfLineInvisibles?[invisibleIndex++]
            lineHTML += "<span class='invisible-character'>#{invisible}</span>"
          else
            lineHTML += ' '
        lineHTML += "</span>"

      while invisibleIndex < endOfLineInvisibles?.length
        lineHTML += "<span class='invisible-character'>#{endOfLineInvisibles[invisibleIndex++]}</span>"

      lineHTML
    else
      @buildEndOfLineHTML(id) or '&nbsp;'

  buildLineInnerHTML: (id) ->
    lineState = @newTileState.lines[id]

    {firstNonWhitespaceIndex, firstTrailingWhitespaceIndex, invisibles} = lineState
    lineIsWhitespaceOnly = firstTrailingWhitespaceIndex is 0

    @htmlBuilder.reset()
    @characterIterator.reset(lineState)
    @tokenIterator.reset(lineState)
    scopeTags = []

    while @characterIterator.next()
      if @characterIterator.isAtBeginningOfToken()
        tokenStart = @characterIterator.getTokenStart()
        tokenEnd = @characterIterator.getTokenEnd()

        for scope in @characterIterator.getScopeEnds()
          @htmlBuilder.closeTag(scopeTags.pop())

        for scope in @characterIterator.getScopeStarts()
          scopeTag = new Tag("span", scope.replace(/\.+/g, ' '))
          @htmlBuilder.openTag(scopeTag)
          scopeTags.push(scopeTag)

        if hasLeadingWhitespace = tokenStart < firstNonWhitespaceIndex
          tokenFirstNonWhitespaceIndex = firstNonWhitespaceIndex - tokenStart
        else
          tokenFirstNonWhitespaceIndex = null

        if hasTrailingWhitespace = tokenEnd > firstTrailingWhitespaceIndex
          tokenFirstTrailingWhitespaceIndex = Math.max(0, firstTrailingWhitespaceIndex - tokenStart)
        else
          tokenFirstTrailingWhitespaceIndex = null

        hasIndentGuide =
          @newState.indentGuidesVisible and
            (hasLeadingWhitespace or lineIsWhitespaceOnly)

        hasInvisibleCharacters =
          (invisibles?.tab and @characterIterator.isHardTab()) or
            (invisibles?.space and (hasLeadingWhitespace or hasTrailingWhitespace))

      if @characterIterator.beginsLeadingWhitespace()
        if @characterIterator.isHardTab()
          classes = 'hard-tab'
          classes += ' leading-whitespace'
          classes += ' indent-guide' if hasIndentGuide
          classes += ' invisible-character' if hasInvisibleCharacters
        else
          classes = 'leading-whitespace'
          classes += ' indent-guide' if hasIndentGuide
          classes += ' invisible-character' if hasInvisibleCharacters

        leadingWhitespaceTag = new Tag("span", classes)
        @htmlBuilder.openTag(leadingWhitespaceTag)

      if @characterIterator.beginsTrailingWhitespace()
        if @characterIterator.isHardTab()
          classes = 'hard-tab'
          classes += ' trailing-whitespace'
          classes += ' indent-guide' if hasIndentGuide
          classes += ' invisible-character' if hasInvisibleCharacters
        else
          tokenIsOnlyWhitespace = tokenFirstTrailingWhitespaceIndex is 0

          classes = 'trailing-whitespace'
          classes += ' indent-guide' if hasIndentGuide and not tokenFirstNonWhitespaceIndex? and tokenIsOnlyWhitespace
          classes += ' invisible-character' if hasInvisibleCharacters

        trailingWhitespaceTag = new Tag("span", classes)
        @htmlBuilder.openTag(trailingWhitespaceTag)

      @htmlBuilder.put(@characterIterator.getChar())

      if @characterIterator.endsLeadingWhitespace()
        @htmlBuilder.closeTag(leadingWhitespaceTag)

      if @characterIterator.endsTrailingWhitespace()
        @htmlBuilder.closeTag(trailingWhitespaceTag)

    for scope in @characterIterator.getScopeEnds()
      @htmlBuilder.closeTag(scopeTags.pop())

    for scope in @characterIterator.getScopes()
      @htmlBuilder.closeTag(scopeTags.pop())

    @htmlBuilder.toString() + @buildEndOfLineHTML(id)

  buildEndOfLineHTML: (id) ->
    {endOfLineInvisibles} = @newTileState.lines[id]

    html = ''
    if endOfLineInvisibles?
      for invisible in endOfLineInvisibles
        html += "<span class='invisible-character'>#{invisible}</span>"
    html

  updateLineNode: (id) ->
    oldLineState = @oldTileState.lines[id]
    newLineState = @newTileState.lines[id]

    lineNode = @lineNodesByLineId[id]

    if @newState.width isnt @oldState.width
      lineNode.style.width = @newState.width + 'px'

    newDecorationClasses = newLineState.decorationClasses
    oldDecorationClasses = oldLineState.decorationClasses

    if oldDecorationClasses?
      for decorationClass in oldDecorationClasses
        unless newDecorationClasses? and decorationClass in newDecorationClasses
          lineNode.classList.remove(decorationClass)

    if newDecorationClasses?
      for decorationClass in newDecorationClasses
        unless oldDecorationClasses? and decorationClass in oldDecorationClasses
          lineNode.classList.add(decorationClass)

    oldLineState.decorationClasses = newLineState.decorationClasses

    if newLineState.top isnt oldLineState.top
      lineNode.style.top = newLineState.top + 'px'
      oldLineState.top = newLineState.top

    if newLineState.screenRow isnt oldLineState.screenRow
      lineNode.dataset.screenRow = newLineState.screenRow
      oldLineState.screenRow = newLineState.screenRow
      @lineIdsByScreenRow[newLineState.screenRow] = id

  lineNodeForScreenRow: (screenRow) ->
    @lineNodesByLineId[@lineIdsByScreenRow[screenRow]]

  measureCharactersInNewLines: ->
    for id, lineState of @oldTileState.lines
      unless @measuredLines.has(id)
        lineNode = @lineNodesByLineId[id]
        @measureCharactersInLine(id, lineState, lineNode)
    return

  measureCharactersInLine: (lineId, tokenizedLine, lineNode) ->
    rangeForMeasurement = null
    iterator = null
    charIndex = 0

    @tokenIterator.reset(tokenizedLine)
    while @tokenIterator.next()
      scopes = @tokenIterator.getScopes()
      text = @tokenIterator.getText()
      charWidths = @presenter.getScopedCharacterWidths(scopes)

      textIndex = 0
      while textIndex < text.length
        if @tokenIterator.isPairedCharacter()
          char = text
          charLength = 2
          textIndex += 2
        else
          char = text[textIndex]
          charLength = 1
          textIndex++

        continue if char is '\0'

        unless charWidths[char]?
          unless textNode?
            rangeForMeasurement ?= document.createRange()
            iterator =  document.createNodeIterator(lineNode, NodeFilter.SHOW_TEXT, AcceptFilter)
            textNode = iterator.nextNode()
            textNodeLength = textNode.textContent.length
            textNodeIndex = 0
            nextTextNodeIndex = textNodeLength

          while nextTextNodeIndex <= charIndex
            textNode = iterator.nextNode()
            textNodeLength = textNode.textContent.length
            textNodeIndex = nextTextNodeIndex
            nextTextNodeIndex = textNodeIndex + textNodeLength

          i = charIndex - textNodeIndex
          rangeForMeasurement.setStart(textNode, i)

          if i + charLength <= textNodeLength
            rangeForMeasurement.setEnd(textNode, i + charLength)
          else
            rangeForMeasurement.setEnd(textNode, textNodeLength)
            atom.assert false, "Expected index to be less than the length of text node while measuring", (error) =>
              editor = @presenter.model
              screenRow = tokenizedLine.screenRow
              bufferRow = editor.bufferRowForScreenRow(screenRow)

              error.metadata = {
                grammarScopeName: editor.getGrammar().scopeName
                screenRow: screenRow
                bufferRow: bufferRow
                softWrapped: editor.isSoftWrapped()
                softTabs: editor.getSoftTabs()
                i: i
                charLength: charLength
                textNodeLength: textNode.length
              }
              error.privateMetadataDescription = "The contents of line #{bufferRow + 1}."
              error.privateMetadata = {
                lineText: editor.lineTextForBufferRow(bufferRow)
              }
              error.privateMetadataRequestName = "measured-line-text"

          charWidth = rangeForMeasurement.getBoundingClientRect().width
          @presenter.setScopedCharacterWidth(scopes, char, charWidth)

        charIndex += charLength

    @measuredLines.add(lineId)

  clearMeasurements: ->
    @measuredLines.clear()
