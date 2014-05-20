util = require 'util'
combiners = require './combiners'
debug_graph = require './debug_graph'
helpers = require './helpers'
parser_state = require './parser_state'
log = console.log
TYPES = require 'coffeenode-types'

DebugGraph = debug_graph.DebugGraph

implicit = helpers.implicit
resolve = helpers.resolve

ParserState = parser_state.ParserState
Match = parser_state.Match
NoMatch = parser_state.NoMatch

_parser_id = 0

# create a new Parser object:
#   - kind: type of parser, in one word ("alt", "optional", ...)
#   - nested: list of nested parsers, if this is a combiner
#   - describer: function that takes the 'nested' list and returns a
#       description of what was expected ("x or y or z")
#   - matcher: function that takes a state and continuation and attempts to
#       match
newParser = (kind, options = {}) ->
  options.nested ?= []
  options.describer ?= kind
  options.matcher ?= (state, cont) -> throw new Error("Undefined matcher")
  if options.wrap?
    options.nested = [ options.wrap ]
    options.describer = (ps) -> ps.join()
  new Parser(kind, options.nested, options.describer, options.matcher)


_count = 0
class Parser
  constructor: (@kind, @nested, @describer, @matcher) ->
    @id = _parser_id++

  nestedList: ->
    if @recursing then return "..."
    if @nested.length == 0 then return ""
    @recursing = true
    rv = @nested.map((p) -> resolve(p).nestedList()).join(", ")
    @recursing = false
    "(#{rv})"

  description: ->
    if @recursing then return "..."
    if typeof @describer == "string" then return @describer
    @recursing = true
    ps = @nested.map((p) -> resolve(p).description())
    @recursing = false
    @describer = @describer(ps)
    @describer

  toString: ->
    "Parser[#{@id}, #{@kind}]" + @nestedList()

  # create a dot graph of the parser nesting
  toDot: (maxLength = 40) ->
    seen = {}
    nodes = []
    edges = []
    traverse = (parser) ->
      seen[parser.id] = true
      nodes.push { id: parser.id, kind: parser.kind, description: parser.description() }
      for p in parser.nested
        p = resolve(p)
        edges.push { from: parser.id, to: p.id }
        if not seen[p.id]? then traverse(p)
    traverse @
    edges = edges.map (e) -> "  \"#{e.from}\" -> \"#{e.to}\";"
    nodes = nodes.map (n) ->
      description = if n.description.length > maxLength then "#{n.description[...maxLength]}..." else n.description
      description = description.replace(/\\/g, "\\\\").replace(/"/g, "\\\"")
      kind = n.kind.replace(/\\/g, "\\\\").replace(/"/g, "\\\"")
      label = "#{kind}\\n#{description}"
      "  \"#{n.id}\" [label=\"#{label}\"];"
    data = [
      "digraph packrattle {"
      "  node [fontname=Courier];"
    ]
    data = data.concat(edges)
    data.push ""
    data = data.concat(nodes)
    data.push "}"
    data.join("\n") + "\n"

  # helper for internal use: immediately fail.
  fail: (state, cont) ->
    cont(new NoMatch(state, "Expected " + @description()))

  # executes @matcher, passing the result (Match or NoMatch) to 'cont'.
  parse: (state, cont) ->
    _count += 1
    state = state.deeper(@)
    entry = state.getCache(@)
    if entry.continuations.length == 0
      # first to try it!
      entry.continuations.push cont
      state.addJob (=> "parse: #{state}, #{@toString()}"), =>
        @matcher state, (rv) =>
          # push our (new?) result
          found = false
          for r in entry.results
            if r.equals(rv) then found = true
          if not found
            entry.results.push rv
            for c in entry.continuations then c(rv)
    else
      entry.continuations.push cont
      for r in entry.results then cont(r)

  # consume an entire text with this parser. convert failure into an exception.
  run: (text, options) ->
    rv = consume(@, text, options)
    if not rv.ok
      e = new Error(rv.message)
      e.state = rv.state
      throw e
    rv.match

  # transformers: []

  # ----- transformations and combinations:
  transform: ( transformer ) ->
    ### use like `p = p.transform ( text ) -> ...`; the function passed to `transform` will be called once
    before parsing starts and is expected to return a new version of the source text. ###
    newParser "transform",
      wrap: @
      matcher: (state, cont) =>
        log '©8372'
        state[ 'internal' ][ 'text' ] = text = transformer state[ 'internal' ][ 'text' ]
        state[ 'internal' ][ 'end'  ] = text.length
        log state
        @parse state, ( rv ) ->
          return cont rv

  # transforms the error message of a parser
  onFail: (newMessage) ->
    newParser "onFail",
      wrap: @
      matcher: (state, cont) =>
        @parse state, (rv) ->
          if rv.ok or rv.abort then return cont(rv)
          cont(new NoMatch(rv.state, newMessage, rv.abort))

  # transforms the result of a parser if it succeeds.
  onMatch: (f) ->
    newParser "onMatch",
      wrap: @
      matcher: (state, cont) =>
        @parse state, (rv) ->
          if not rv.ok then return cont(rv)
          if typeof f == "function"
            try
              result = f(rv.match, rv.state.flip())
              if result instanceof Parser
                result.parse(rv.state, cont)
              else
                cont(new Match(rv.state, result, rv.commit))
            catch e
              log '\x1b[38;05;33m©314\x1b[38;05;124m\nOriginal Error:\n' + e.stack + '\n\x1b[0m'
              cont(new NoMatch(rv.state, e.toString(), rv.commit))
          else
            cont(new Match(rv.state, f, rv.commit))

  # only succeed if f(match) returns true.
  matchIf: (f) ->
    newParser "matchIf",
      wrap: @
      matcher: (state, cont) =>
        @parse state, (rv) =>
          if not rv.ok then return cont(rv)
          if not f(rv.match) then return cont(new NoMatch(state, "Expected " + @description(), rv.commit))
          cont(rv)

  describe: (message) ->
    @describer = -> message
    @onFail "Expected #{message}"

  # ----- convenience methods for accessing the combinators

  then: (p) -> combiners.chain @, p, (a, b) -> [ a, b ]

  or: (others...) -> combiners.alt(@, others...)

  optional: (defaultValue="") -> combiners.optional(@, defaultValue)

  check: -> combiners.check(@)

  commit: -> combiners.commit(@)

  not_: -> combiners.not_(@)

  drop: -> combiners.drop(@)

  repeat: (minCount, maxCount) -> combiners.repeat(@, minCount, maxCount)

  times: (count) -> combiners.repeat(@, count, count)


# matches the end of the string.
end = newParser "end",
  matcher: (state, cont) ->
    if state.loc.pos == state.internal.end then cont(new Match(state, null, false)) else @fail(state, cont)

# never matches anything.
reject = newParser "reject",
  matcher: (state, cont) ->
    cont(new NoMatch(state, "failure"))

# always matches without consuming input and yields the given value.
succeed = (v) ->
  newParser "succeed",
    matcher: (state, cont) ->
      cont(new Match(state, v, false))

# matches a literal string.
string = (s) ->
  len = s.length
  newParser "lit: '#{s}'",
    describer: "'#{s}'"
    matcher: (state, cont) ->
      candidate = state.internal.text.slice(state.loc.pos, state.loc.pos + len)
      if candidate == s
        cont(new Match(state.advance(len), candidate, false))
      else
        @fail(state, cont)

# matches a regex
regex = (r) ->
  i = if r.ignoreCase then "i" else ""
  m = if r.multiline then "m" else ""
  source = if r.source[0] == "^" then r.source else ("^" + r.source)
  r2 = new RegExp(source, i + m)
  newParser "re: #{r.toString()}",
    describer: r.toString()
    matcher: (state, cont) ->
      m = r2.exec(state.internal.text.slice(state.loc.pos))
      if m? then cont(new Match(state.advance(m[0].length), m, false)) else @fail(state, cont)

# ----- top-level API:

# execute a parser over a string.
parse = (p, str, options = {}) ->
  _count = 0
  state = if str instanceof ParserState then str else new ParserState(str)
  state.stateName = "start"
  if options.debugGraph then state.startDebugGraph()
  p = resolve(p)
  successes = []
  failures = []
  state.addJob (=> "start: #{state}, #{p.toString()}"), ->
    p.parse state, (rv) ->
      if rv.ok
        rv.state.logSuccess()
        successes.push rv
      else
        rv.state.logFailure()
        failures.push rv
  while state.internal.trampoline.ready() and successes.length == 0
    state.internal.trampoline.next()
  # message with 'abort' set has highest priority. secondary sort by index.
  failures.sort (a, b) ->
    if a.abort != b.abort
      if b.abort then 1 else -1
    else
      b.state.depth - a.state.depth
  if successes.length > 0
    successes[0]
  else
    failures[0]

# must match the entire string, to the end.
consume = (p, str, options) ->
  p = combiners.chain implicit(p), end, (a, b) -> a
  parse(p, str, options)


exports.newParser = newParser
exports.Parser = Parser

exports.end = end
exports.reject = reject
exports.succeed = succeed
exports.string = string
exports.regex = regex

exports.parse = parse
exports.consume = consume
