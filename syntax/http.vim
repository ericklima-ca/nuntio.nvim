" Vim syntax file for HTTP (.http and .rest files)
" Language: HTTP Request Client
" Maintainer: nuntio.nvim

if exists("b:current_syntax")
  finish
endif

let s:cpo_save = &cpo
set cpo&vim

" Include JSON syntax for request bodies
if !exists("g:http_no_json_syntax")
  silent! syntax include @JSON syntax/json.vim
  unlet! b:current_syntax
endif

" Include XML syntax for SOAP/XML request bodies
if !exists("g:http_no_xml_syntax")
  silent! syntax include @XML syntax/xml.vim
  unlet! b:current_syntax
endif

" Comments (# and // comments)
syn match httpComment "^\s*[#\/].*$" contains=httpMetadata,httpDelimiter
syn match httpComment "\s\+[#\/].*$" contained

" File/document variables: @var = value
syn match httpDocVar "^@[a-zA-Z0-9_\-]\+\s*=" contains=httpDocVarName,httpOperator
syn match httpDocVarName "^@[a-zA-Z0-9_\-]\+" contained
syn match httpOperator "=" contained

" Metadata directives: # @name, # @prompt, # @curl-*, # @jq, etc.
syn match httpMetadata "^\s*#\s*@[a-zA-Z0-9_\-]\+.*$" contains=httpMetadataTag,httpVariable
syn match httpMetadataTag "@[a-zA-Z0-9_\-]\+" contained

" Request section delimiter: ### [name]
syn match httpDelimiter "^\s*###.*$" contains=httpDelimiterHeader
syn match httpDelimiterHeader "^###" contained

" Shared block delimiter: ### Shared / ### Shared each (takes precedence)
syn match httpSharedDelimiter "^\s*###\s\+[Ss]hared\(\s\+each\)\?.*$" contains=httpSharedHeader,httpSharedKeyword
syn match httpSharedHeader "^###" contained
syn match httpSharedKeyword "\<[Ss]hared\(\s\+each\)\?\>" contained

" Template Variables: {{var}}, {{$uuid}}, etc.
" penetrates into JSON strings, headers, URLs, and doc variables
syn match httpVariable "{{.\{-}}}" containedin=@JSON,jsonString,jsonKeyword,httpUrl,httpHeader,httpDocVar,httpMetadata

" HTTP Methods (with distinct per-method colors)
syn keyword httpMethodGet GET containedin=httpUrl
syn keyword httpMethodPost POST containedin=httpUrl
syn keyword httpMethodPut PUT containedin=httpUrl
syn keyword httpMethodDelete DELETE containedin=httpUrl
syn keyword httpMethodPatch PATCH containedin=httpUrl
syn keyword httpMethodHead HEAD containedin=httpUrl
syn keyword httpMethodOptions OPTIONS containedin=httpUrl
syn keyword httpMethodConnect CONNECT containedin=httpUrl
syn keyword httpMethodTrace TRACE containedin=httpUrl

" HTTP Version
syn match httpVersion "HTTP\/[0-9]\+\(\.[0-9]\+\)\?"

" URLs and Query Parameters
syn match httpUrl "\(https\?:\/\/\|\/\|}}\zs\/\)[^ \t\r\n]*" contains=httpVariable,httpQueryKey,httpQueryDelimiter
syn match httpQueryDelimiter "[?&=]" contained
syn match httpQueryKey "[?&]\zs[a-zA-Z0-9_\-]\+" contained

" Headers: Header-Name: value
syn match httpHeader "^[A-Za-z0-9_\-]\+\s*:" contains=httpHeaderName
syn match httpHeaderName "^[A-Za-z0-9_\-]\+" contained

" Simplified Multipart Form Fields: key = value or file = < ./path; type=...
syn match httpFormParam ";\s*type=[a-zA-Z0-9_\-\.\/]\+" contains=httpFormTypeKey
syn match httpFormTypeKey ";\s*type=" contained

" Body file includes: < ./file or <@ ./file
syn match httpFileInclude "^\s*<[@\s]\+.*$" contains=httpVariable,httpFileIncludeOp
syn match httpFileIncludeOp "<[@\s]\+" contained

" Response redirects: >> file or >>! file
syn match httpRedirect "^\s*>>!\?\s\+.*$" contains=httpVariable,httpRedirectOp
syn match httpRedirectOp ">>!\?" contained

" Embedded JSON body regions (single-line or multi-line)
if !exists("g:http_no_json_syntax")
  syn region httpJsonBody start="^\s*[{\[]" end="^\s*###"me=s-1 contains=@JSON,httpVariable keepend
endif

" Embedded XML body regions
if !exists("g:http_no_xml_syntax")
  syn region httpXmlBody start="^\s*<[?a-zA-Z]" end="^\s*###"me=s-1 contains=@XML,httpVariable keepend
endif

" Syntax Synchronization
syntax sync minlines=50 maxlines=500

" Default Highlight Links (compatible with nuntio highlight groups)
hi def link httpMethodGet NuntioMethodGet
hi def link httpMethodPost NuntioMethodPost
hi def link httpMethodPut NuntioMethodPut
hi def link httpMethodDelete NuntioMethodDelete
hi def link httpMethodPatch NuntioMethodPatch
hi def link httpMethodHead NuntioMethodHead
hi def link httpMethodOptions NuntioMethodOptions
hi def link httpMethodConnect Keyword
hi def link httpMethodTrace Keyword

hi def link httpDocVarName NuntioDocVar
hi def link httpOperator Operator
hi def link httpDelimiter NuntioDividerText
hi def link httpDelimiterHeader NuntioDividerIcon
hi def link httpSharedDelimiter NuntioSharedDelimiter
hi def link httpSharedHeader NuntioSharedDelimiter
hi def link httpSharedKeyword NuntioSharedKeyword
hi def link httpComment Comment
hi def link httpMetadata SpecialComment
hi def link httpMetadataTag NuntioMetadataTag
hi def link httpVariable NuntioVariable
hi def link httpHeaderName NuntioHeaderKey
hi def link httpUrl NuntioUrl
hi def link httpQueryDelimiter Delimiter
hi def link httpQueryKey Identifier
hi def link httpFormParam Type
hi def link httpFormTypeKey Operator
hi def link httpVersion Number
hi def link httpFileIncludeOp NuntioOperator
hi def link httpFileInclude String
hi def link httpRedirectOp NuntioOperator
hi def link httpRedirect String

let b:current_syntax = "http"

let &cpo = s:cpo_save
unlet s:cpo_save
