; extends
;
; Inject markdown into jupytext comment lines that are NOT cell markers.
; The #offset! strips the leading "# " (2 chars) so render-markdown.nvim
; sees clean markdown rather than Python comment syntax.

((comment) @injection.content
  (#lua-match? @injection.content "^# [^%%]")
  (#offset! @injection.content 0 2 0 0)
  (#set! injection.combined)
  (#set! injection.language "markdown"))
