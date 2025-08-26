local v = vim.v
local fn = vim.fn
local util = require('pretty-fold.util')
local M = {
   cache = {}
}

---@param config? table
---@return string content modified first nonblank line of the folded region
function M.content(config)
   ---The content of the 'content' section.
   ---@type string
   local content = fn.getline(v.foldstart)

   local filetype = vim.bo.filetype

   if not M.cache[filetype] then M.cache[filetype] = {} end
   local cache = M.cache[filetype]

   if not cache.comment_tokens then
      local comment_tokens = fn.split(vim.bo.commentstring, '%s') -- or {''}

      -- Trim redundant spaces from the beggining and the end if any.
      if not vim.tbl_isempty(comment_tokens) then
         for i = 1, #comment_tokens do
            comment_tokens[i] = vim.trim(comment_tokens[i])
         end
      end

      -- Add additional comment signs from 'config.comment_signs' table.
      if not vim.tbl_isempty(config.comment_signs) then
         comment_tokens = {
            #comment_tokens == 1 and unpack(comment_tokens) or comment_tokens,
            unpack(config.comment_signs)
         }
      end

      comment_tokens = util.unique_comment_tokens(comment_tokens)
      table.sort(comment_tokens, function(a, b)
         if type(a) == "table" then a = a[1] end
         if type(b) == "table" then b = b[1] end
         return #a > #b and true or false
      end)

      cache.comment_tokens = {
         raw = comment_tokens,
         escaped = util.deep_pesc(comment_tokens)
      }
   end
   local comment_tokens = cache.comment_tokens

   -- Make cache for regexes.
   if not cache.regex then
      -- See ':help /\M'
      cache.regex = {}

      -- List of regexes for seeking all comment tokens at the beggining of the line.
      cache.regex.all_comment_tokens_at_start = {}

      for i = 1, #comment_tokens.raw do
         local token = comment_tokens.raw[i][1] or comment_tokens.raw[i]

         -- token: '--'
         -- regex: \M^\%(\s\*--\s\*\)\*$
         -- Example of what this is for:
         -- 'test( -- comment'     ->  '-- comment'
         table.insert(
            cache.regex.all_comment_tokens_at_start,
            vim.regex(table.concat{ [[\M^\%(\s\*]], token, [[\s\*\)\*]] })
         )
      end
   end

   -- Make cache for Lua pattern.
   if not cache.lua_patterns then
      cache.lua_patterns = {}

      -- Line consists only of comment token.
      cache.lua_patterns.str_with_only_comment_token = {}

      -- Comment token at the beggining of the line
      cache.lua_patterns.comment_token_at_start = {}

      cache.lua_patterns.comment_token_at_eol = {}
      cache.lua_patterns.comment_substring_at_eol = {}

      for _, token in ipairs(comment_tokens.escaped) do
         token = token[1] or token

         table.insert(
            cache.lua_patterns.str_with_only_comment_token,
            table.concat{ '^%s*', token, '%s*$' }
         )
         table.insert(
            cache.lua_patterns.comment_token_at_start,
            table.concat{ '^', token, '%s*' }
         )
         table.insert(
            cache.lua_patterns.comment_token_at_eol,
            table.concat{ '%s*', token, '%s*$' }
         )
         table.insert(
            cache.lua_patterns.comment_substring_at_eol,
            table.concat{ '%s*', token, '.*$' }
         )
      end

   end

   -- if vim.wo.foldmethod == 'marker' and config.remove_fold_markers then
   if config.remove_fold_markers then
      local fmr = vim.opt.foldmarker:get()[1]
      if not cache.lua_patterns[fmr] then
         cache.lua_patterns[fmr] = table.concat{ '%s?', vim.pesc(fmr), '%d*' }
      end
      content = content:gsub(cache.lua_patterns[fmr], '')

      for _, pattern in ipairs(cache.lua_patterns.comment_token_at_eol) do
         content = content:gsub(pattern, '')
      end
   end

   -- If after removimg fold markers and comment signs we get blank line,
   -- take next nonblank.
   do
      local blank = content:match('^%s*$') and true or false

      -- Check if content string consists only of comment sign.
      local only_comment_sign = false
      if not blank then
         for _, pattern in ipairs(cache.lua_patterns.str_with_only_comment_token) do
            if content:match(pattern) then
               only_comment_sign = true
               break
            end
         end
      end

      if blank or only_comment_sign then
         local line_num = fn.nextnonblank(v.foldstart + 1)
         if line_num ~= 0 and line_num <= v.foldend then
            if config.process_comment_signs or blank then
               content = fn.getline(line_num)
            else
               content = content:gsub('%s+$', '')
               local add_line = vim.trim(fn.getline(line_num))
               for _, pattern in ipairs(cache.lua_patterns.comment_token_at_start) do
                  add_line = add_line:gsub(pattern, '')
               end
               content = table.concat({ content, ' ', add_line })
            end
         end
      end
   end

   if not vim.tbl_isempty(config.stop_words) then
      for _, w in ipairs(config.stop_words) do
         content = content:gsub(w, '')
      end
   end

   -- Add matchup pattern
   if type(config.add_close_pattern) == "boolean"  -- Add matchup pattern
      and config.add_close_pattern
   then
      local str = content
      local found_patterns = {}
      for _, pat in ipairs(config.matchup_patterns) do
         local found = {}

         local start, stop = nil, 0
         while stop do
            start, stop = str:find(pat[1], stop + 1)
            if start then
               table.insert(found, { start = start, stop = stop,
                                     pat = pat[1], oppening = true })
            end
         end

         for _, f in ipairs(found) do
            str = table.concat {
               str:sub(1, f.start - 1),
               string.rep('Q', f.stop - f.start + 1),
               str:sub(f.stop + 1)
            }
         end

         local num_op = #found  -- number of opening patterns
         if num_op > 0 then
            start, stop = nil, 0
            while stop do
               start, stop = str:find(vim.pesc(pat[2]), stop + 1)
               if start then
                  table.insert(found, { start = start, stop = stop,
                                        pat = pat[2], oppening = false })
               end
               -- If number of closing patterns become equal to number of openning
               -- patterns, then break.
               if #found - num_op == num_op then break end
            end
         end

         if num_op > 0 and num_op ~= #found then
            table.sort(found, function(a, b)
               return a.start < b.start and true or false
            end)

            ---previous, current, next
            local p, c, n = nil, 1, 2
            while true do
               if found[c].pat == pat[1] and found[n].pat == pat[2] then
                  table.remove(found, n)
                  table.remove(found, c)
                  if p then
                     c, n = p, c
                     p = p > 1 and p-1 or nil
                  end
               else
                  c, n = c + 1, n + 1
                  p = (p or 0) + 1
               end
               if n > #found then break end
            end
         end

         for _, f in ipairs(found) do
            table.insert(found_patterns,
               { pat = pat, pos = f.start, oppening = f.oppening })
         end
      end

      table.sort(found_patterns, function(a, b)
         return a.pos < b.pos and true or false
      end)

      while true do
         if found_patterns[1] and not found_patterns[1].oppening then
            table.remove(found_patterns, 1)
         else
            break
         end
      end

      if not vim.tbl_isempty(found_patterns) then
         local closing_comment_str

         for i = 1, #comment_tokens.raw do
            local regex = cache.regex.all_comment_tokens_at_start[i]

            -- The content string with all comment tokens stripped from the
            -- beginning of the line.
            local striped_content = content
            -- Stripped comment tokens.
            local opening_comment_tokens = ''

            local start, stop = regex:match_str(content)
            if start then
               opening_comment_tokens = content:sub(start + 1, stop)
               striped_content = content:sub(stop + 1)
            end

            local pattern = cache.lua_patterns.comment_substring_at_eol[i]
            start = striped_content:find(pattern)

            if start then
               closing_comment_str = striped_content:sub(start)
               content = content:sub(1, #opening_comment_tokens + start - 1)
               break
            end
         end

         local ellipsis = ' ... '

         str = { content, ellipsis }
         for i = #found_patterns, 1, -1 do
            table.insert(str, found_patterns[i].pat[2])
         end

         if closing_comment_str then
            table.insert(str, closing_comment_str)
         end

         content = table.concat(str)

         local brackets = {
            { "{ %.%.%. }",   "{...}" }, -- { ... }  ->  {...}
            { "%( %.%.%. %)", "(...)" }, -- ( ... )  ->  (...)
            { "%[ %.%.%. %]", "[...]" }, -- [ ... ]  ->  [...]
            { "< %.%.%. >",   "<...>" }  -- < ... >  ->  <...>
         }

         for _, b in ipairs(brackets) do
            content = content:gsub(b[1], b[2])
         end

      end

   elseif config.add_close_pattern == 'last_line' then
      local last_line = fn.getline(v.foldend)

      for _, token in ipairs(comment_tokens.escaped) do
         last_line = last_line:gsub(token[1] or token .. '.*$', '')
      end

      last_line = vim.trim(last_line)
      for _, p in ipairs(config.matchup_patterns) do
         if content:find( p[1] ) and last_line:find( p[2] ) then

            local ellipsis = (#p[2] == 1) and '...' or ' ... '

            local closing_comment_str = ''
            for _, c in ipairs(comment_tokens.escaped) do
               local c_start = content:find(table.concat{'%s*', c[1] or c, '.*$'})

               if c_start then
                  closing_comment_str = content:sub(c_start)
                  content = content:sub(1, c_start - 1)
                  break
               end
            end

            content = table.concat{ content, ellipsis, last_line, closing_comment_str }
            break
         end
      end
   end

   -- Process comment signs
   if config.process_comment_signs == 'spaces' then
      local raw_token = vim.tbl_flatten(comment_tokens.raw)
      for i, token in ipairs(vim.tbl_flatten( comment_tokens.escaped )) do
         content = content:gsub(token, string.rep(' ', #raw_token[i]))
      end
   elseif config.process_comment_signs == 'delete' then
      for _, sign in ipairs(vim.tbl_flatten( comment_tokens.escaped )) do
         content = content:gsub(sign, '')
      end
   end

   -- Replace all tabs with spaces with respect to %tabstop.
   content = content:gsub('\t', string.rep(' ', vim.bo.tabstop))

   if vim.bo.filetype == 'markdown' then
     content = content:gsub('#', '')
   end

   if config.keep_indentation then
      local opening_blank_substr = content:match('^%s%s+')
      if opening_blank_substr then
         content = content:gsub(
            opening_blank_substr,
            config.fill_char:rep(#opening_blank_substr - 1)..' ',
            -- config.fill_char:rep(fn.strdisplaywidth(opening_blank_substr) - 1)..' ',
            1)
      end
   elseif config.sections.left[1] == 'content' then
      content = content:gsub('^%s*', '') -- Strip all indentation.
   else
      content = content:gsub('^%s*', ' ')
   end

   content = content:gsub('%s*$', '')
   content = content..' '

   -- Exchange all occurrences of multiple spaces inside the text with
   -- 'fill_char', like this:
   -- "//      Text"  ->  "// ==== Text"
   for blank_substr in content:gmatch('%s%s%s+') do
      content = content:gsub(
         blank_substr,
         ' '..string.rep(config.fill_char, #blank_substr - 2)..' ',
         1)
   end

   return content
end

---@return string
function M.number_of_folded_lines()
   return string.format('%d lines', v.foldend - v.foldstart + 1)
end

---@return string
function M.percentage()
   local folded_lines = v.foldend - v.foldstart + 1  -- The number of folded lines.
   local total_lines = vim.api.nvim_buf_line_count(0)
   local pnum = math.floor(100 * folded_lines / total_lines)
   if pnum == 0 then
      pnum = tostring(100 * folded_lines / total_lines):sub(2, 3)
   elseif pnum < 10 then
      pnum = ' '..pnum
   end
   return pnum .. '%'
end

return setmetatable(M, {
   __index = function(_, custom_section)
      return custom_section
   end
})
