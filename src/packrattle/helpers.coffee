WeakMap = require 'weakmap'
parser = require './parser'
TYPES = require 'coffeenode-types'

#
# helper functions used by the parsers & combiners -- not exported.
#

lazyCache = new WeakMap()
fromLazyCache = (p) ->
  memo = lazyCache.get(p)
  if not memo?
    memo = p()
    lazyCache.set(p, memo)
  memo

# helper to defer an unresolved parser into one that can be combined
defer = (p) ->
  parser.newParser "defer",
    wrap: p,
    matcher: (state, cont) ->
      p = resolve(p)
      p.parse state, cont

# turn strings, regexen, and arrays into parsers implicitly.
implicit = ( p ) ->
  parser = require './parser'
  combiners = require './combiners'
  return switch type = TYPES.type_of p
    when 'text'     then parser.string  p
    when 'jsregex'  then parser.regex   p
    when 'list'     then combiners.seq  p...
  return p

# allow functions to be passed in, and resolved only at parse-time.
resolve = (p) ->
  if not (typeof p == "function") then return implicit(p)
  p = fromLazyCache(p)
  p = implicit(p)
  if not p? then throw new Error("Can't resolve parser")
  p


exports.defer = defer
exports.implicit = implicit
exports.resolve = resolve
