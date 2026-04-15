-- blog-filter-ifs.lua
-- Pandoc Lua filter that prepares files for publication on the Institute for
-- Family Studies (IFS) web blog.
--
-- Transformations:
--   (1) Figures are replaced with "[Figure N: caption]" placeholders. The
--       notes and source text beneath each figure are moved into a footnote
--       attached to the placeholder.
--   (2) In-text citations (\cite and \citep) are replaced with the full names
--       of all authors, hyperlinked to the paper's URL from the bibliography.
--       Entries without a URL field render as plain text. The bibliography
--       section is suppressed.
--
-- Installation:
--   Place in ~/.pandoc/filters/ so pandoc can find it by name.
--
-- Usage:
--   pandoc --from latex --bibliography=refs.bib \
--          --lua-filter=blog-filter-ifs.lua paper.tex -o blog.docx

local refs = {}          -- citation key -> {authors, url}
local figure_count = 0

-- Format a list of author names into pandoc inlines
-- e.g. {"Alice Smith", "Bob Jones"} -> "Alice Smith and Bob Jones"
local function author_inlines(authors)
  local out = {}
  for i, name in ipairs(authors) do
    if i == #authors and i > 1 then
      table.insert(out, pandoc.Space())
      table.insert(out, pandoc.Str("and"))
      table.insert(out, pandoc.Space())
    elseif i > 1 then
      table.insert(out, pandoc.Str(","))
      table.insert(out, pandoc.Space())
    end
    table.insert(out, pandoc.Str(name))
  end
  return out
end

-- Build linked (or plain) author inlines for a single citation key
local function cite_inlines(key)
  local ref = refs[key]
  if not ref then return {pandoc.Str("[" .. key .. "]")} end
  local names = author_inlines(ref.authors)
  if ref.url then
    return {pandoc.Link(names, ref.url)}
  end
  return names
end

-- Collect inline content from nested Divs/Paras inside a figure body
local function collect_notes(block, out)
  if block.tag == "Div" then
    for _, child in ipairs(block.content) do
      collect_notes(child, out)
    end
  elseif block.tag == "Para" or block.tag == "Plain" then
    if #out > 0 then table.insert(out, pandoc.Space()) end
    for _, il in ipairs(block.content) do
      table.insert(out, il)
    end
  end
end

-- Entry point: load bibliography, then walk the document
function Pandoc(doc)
  -- Parse bibliography into lookup table
  for _, ref in ipairs(pandoc.utils.references(doc)) do
    local id = tostring(ref.id)
    local authors = {}
    if ref.author then
      for _, a in ipairs(ref.author) do
        table.insert(authors, tostring(a.given) .. " " .. tostring(a.family))
      end
    end
    refs[id] = {authors = authors, url = ref.url and tostring(ref.url) or nil}
  end

  -- Walk the AST
  figure_count = 0
  doc = doc:walk({
    -- Replace Figure blocks with placeholder + footnote
    Figure = function(fig)
      figure_count = figure_count + 1

      -- Caption text
      local cap = ""
      if fig.caption and fig.caption.long and #fig.caption.long > 0 then
        cap = pandoc.utils.stringify(fig.caption.long)
      end

      -- Collect notes from the figure body (inside footnotesize Divs),
      -- skipping Plain blocks that hold the actual graphic
      local notes = {}
      for _, block in ipairs(fig.content) do
        if block.tag == "Plain" and block.content
           and #block.content == 1 and block.content[1].tag == "Image" then
          -- skip the image
        else
          collect_notes(block, notes)
        end
      end

      -- Build placeholder paragraph
      local inlines = {
        pandoc.Str("[Figure"),
        pandoc.Space(),
        pandoc.Str(tostring(figure_count)),
        pandoc.Str(":"),
        pandoc.Space(),
        pandoc.Str(cap),
        pandoc.Str("]"),
      }
      if #notes > 0 then
        table.insert(inlines, pandoc.Note({pandoc.Para(notes)}))
      end
      return pandoc.Para(inlines)
    end,

    -- Replace Cite elements (pandoc-parsed \cite{})
    Cite = function(cite)
      local out = {}
      for i, c in ipairs(cite.citations) do
        if i > 1 then
          table.insert(out, pandoc.Str(";"))
          table.insert(out, pandoc.Space())
        end
        for _, il in ipairs(cite_inlines(c.id)) do
          table.insert(out, il)
        end
      end
      return out
    end,

    -- Replace RawInline \citep{} that pandoc didn't parse as Cite
    RawInline = function(raw)
      if raw.format ~= "latex" then return nil end
      local key = raw.text:match("\\citep?{([^}]+)}")
      if key then
        return cite_inlines(key)
      end
      return nil
    end,
  })

  -- Suppress the bibliography block (no references section needed)
  doc.meta["suppress-bibliography"] = true
  return doc
end
