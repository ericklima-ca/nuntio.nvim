local M = {}

--- LSP CompletionItemKind constants
M.kinds = {
  Text = 1,
  Method = 2,
  Function = 3,
  Constructor = 4,
  Field = 5,
  Variable = 6,
  Class = 7,
  Interface = 8,
  Module = 9,
  Property = 10,
  Unit = 11,
  Value = 12,
  Enum = 13,
  Keyword = 14,
  Snippet = 15,
  Color = 16,
  File = 17,
  Reference = 18,
  Folder = 19,
  EnumMember = 20,
  Constant = 21,
  Struct = 22,
  Event = 23,
  Operator = 24,
  TypeParameter = 25,
}

--- HTTP Methods with descriptions and semantics
M.methods = {
  {
    name = "GET",
    insert_text = "GET ",
    detail = "HTTP GET method",
    doc = "**GET** requests representation of the specified resource.\n\n- **Safe**: Yes\n- **Idempotent**: Yes\n- **Body Allowed**: No (RFC 9110)",
  },
  {
    name = "POST",
    insert_text = "POST ",
    detail = "HTTP POST method",
    doc = "**POST** submits an entity to the specified resource, often causing a change in state or side effects on the server.\n\n- **Safe**: No\n- **Idempotent**: No\n- **Body Allowed**: Yes",
  },
  {
    name = "PUT",
    insert_text = "PUT ",
    detail = "HTTP PUT method",
    doc = "**PUT** replaces all current representations of the target resource with the request payload.\n\n- **Safe**: No\n- **Idempotent**: Yes\n- **Body Allowed**: Yes",
  },
  {
    name = "PATCH",
    insert_text = "PATCH ",
    detail = "HTTP PATCH method",
    doc = "**PATCH** applies partial modifications to a resource.\n\n- **Safe**: No\n- **Idempotent**: No\n- **Body Allowed**: Yes",
  },
  {
    name = "DELETE",
    insert_text = "DELETE ",
    detail = "HTTP DELETE method",
    doc = "**DELETE** deletes the specified resource.\n\n- **Safe**: No\n- **Idempotent**: Yes\n- **Body Allowed**: Optional",
  },
  {
    name = "HEAD",
    insert_text = "HEAD ",
    detail = "HTTP HEAD method",
    doc = "**HEAD** asks for a response identical to a GET request, but without the response body.\n\n- **Safe**: Yes\n- **Idempotent**: Yes\n- **Body Allowed**: No",
  },
  {
    name = "OPTIONS",
    insert_text = "OPTIONS ",
    detail = "HTTP OPTIONS method",
    doc = "**OPTIONS** describes the communication options for the target resource (CORS preflight).\n\n- **Safe**: Yes\n- **Idempotent**: Yes\n- **Body Allowed**: No",
  },
}

--- Standard RFC Headers with documentation
M.headers = {
  {
    name = "Accept",
    insert_text = "Accept: ",
    doc = "**Accept**: Informs the server about the types of data that can be sent back.\n\n*RFC 9110 Section 12.5.1*\n*Common values*: `application/json`, `text/html`, `*/*`",
  },
  {
    name = "Accept-Charset",
    insert_text = "Accept-Charset: ",
    doc = "**Accept-Charset**: Indicates which character encodings are acceptable to the client.\n\n*RFC 9110 Section 12.5.2*",
  },
  {
    name = "Accept-Encoding",
    insert_text = "Accept-Encoding: ",
    doc = "**Accept-Encoding**: Informs the server of the acceptable content-encoding algorithms (usually compression).\n\n*RFC 9110 Section 12.5.3*\n*Common values*: `gzip, deflate, br`",
  },
  {
    name = "Accept-Language",
    insert_text = "Accept-Language: ",
    doc = "**Accept-Language**: Informs the server about the preferred human language of the response.\n\n*RFC 9110 Section 12.5.4*\n*Common values*: `en-US,en;q=0.9`, `pt-BR,pt;q=0.8`",
  },
  {
    name = "Access-Control-Allow-Origin",
    insert_text = "Access-Control-Allow-Origin: ",
    doc = "**Access-Control-Allow-Origin**: Indicates whether the response can be shared with resources with the given origin.\n\n*CORS Specification*",
  },
  {
    name = "Authorization",
    insert_text = "Authorization: ",
    doc = "**Authorization**: Contains the credentials to authenticate a user agent with a server.\n\n*RFC 9110 Section 11.6.2*\n*Common formats*:\n- `Bearer <token>`\n- `Basic <base64(user:pass)>`",
  },
  {
    name = "Cache-Control",
    insert_text = "Cache-Control: ",
    doc = "**Cache-Control**: Holds directives (instructions) for caching in both requests and responses.\n\n*RFC 9111 Section 5.2*\n*Common values*: `no-cache`, `no-store`, `max-age=0`, `must-revalidate`",
  },
  {
    name = "Connection",
    insert_text = "Connection: ",
    doc = "**Connection**: Controls whether the network connection stays open after the current transaction finishes.\n\n*RFC 9110 Section 7.6.1*\n*Common values*: `keep-alive`, `close`",
  },
  {
    name = "Content-Disposition",
    insert_text = "Content-Disposition: ",
    doc = "**Content-Disposition**: Indicates if the content is expected to be displayed inline or downloaded as an attachment.\n\n*RFC 6266*",
  },
  {
    name = "Content-Encoding",
    insert_text = "Content-Encoding: ",
    doc = "**Content-Encoding**: Used to compress the media-type of the payload.\n\n*RFC 9110 Section 8.4*",
  },
  {
    name = "Content-Length",
    insert_text = "Content-Length: ",
    doc = "**Content-Length**: The size of the message body in octets (bytes) sent to the recipient.\n\n*RFC 9110 Section 8.6*",
  },
  {
    name = "Content-Type",
    insert_text = "Content-Type: ",
    doc = "**Content-Type**: Indicates the original media type of the resource (prior to any content encoding).\n\n*RFC 9110 Section 8.3*\n*Common values*: `application/json`, `application/x-www-form-urlencoded`, `multipart/form-data`",
  },
  {
    name = "Cookie",
    insert_text = "Cookie: ",
    doc = "**Cookie**: Contains stored HTTP cookies previously sent by the server with the Set-Cookie header.\n\n*RFC 6265*",
  },
  {
    name = "Host",
    insert_text = "Host: ",
    doc = "**Host**: Specifies the host and port number of the server to which the request is being sent.\n\n*RFC 9110 Section 7.2*",
  },
  {
    name = "If-Match",
    insert_text = "If-Match: ",
    doc = "**If-Match**: Makes the request conditional. The server will send back the requested resource only if it matches one of the listed ETags.\n\n*RFC 9110 Section 13.1.1*",
  },
  {
    name = "If-Modified-Since",
    insert_text = "If-Modified-Since: ",
    doc = "**If-Modified-Since**: Makes the request conditional. Expects 304 Not Modified if the resource has not been modified since the given date.\n\n*RFC 9110 Section 13.1.3*",
  },
  {
    name = "If-None-Match",
    insert_text = "If-None-Match: ",
    doc = "**If-None-Match**: Makes the request conditional. Expects 304 Not Modified if the resource's ETag matches the given value.\n\n*RFC 9110 Section 13.1.2*",
  },
  {
    name = "Origin",
    insert_text = "Origin: ",
    doc = "**Origin**: Indicates where a fetch originates from.\n\n*RFC 6454*",
  },
  {
    name = "Referer",
    insert_text = "Referer: ",
    doc = "**Referer**: The address of the previous web page from which a link to the currently requested page was followed.\n\n*RFC 9110 Section 10.1.3*",
  },
  {
    name = "Sec-WebSocket-Key",
    insert_text = "Sec-WebSocket-Key: ",
    doc = "**Sec-WebSocket-Key**: Used in the WebSocket opening handshake to provide entropy to the server.\n\n*RFC 6455*",
  },
  {
    name = "User-Agent",
    insert_text = "User-Agent: ",
    doc = "**User-Agent**: Contains a characteristic string that allows the network protocol peers to identify the application type, OS, and software vendor.\n\n*RFC 9110 Section 10.1.5*",
  },
  {
    name = "X-Api-Key",
    insert_text = "X-Api-Key: ",
    doc = "**X-Api-Key**: De facto standard header used to transmit API keys and access tokens for service authentication.",
  },
  {
    name = "X-Request-Id",
    insert_text = "X-Request-Id: ",
    doc = "**X-Request-Id**: Common header used for distributed tracing and correlating log entries across microservices.",
  },
}

--- Common MIME types
M.mime_types = {
  { name = "application/json", doc = "JavaScript Object Notation format (*RFC 8259*)" },
  { name = "application/x-www-form-urlencoded", doc = "URL-encoded key-value pairs separated by `&`" },
  { name = "multipart/form-data", doc = "Multipart binary/text file upload with boundaries" },
  { name = "application/xml", doc = "Extensible Markup Language (*RFC 7303*)" },
  { name = "text/plain", doc = "Raw plain text without formatting" },
  { name = "text/html", doc = "HyperText Markup Language" },
  { name = "application/octet-stream", doc = "Arbitrary binary data (*RFC 2046*)" },
  { name = "application/graphql-response+json", doc = "GraphQL specification compliant JSON response" },
  { name = "application/pdf", doc = "Portable Document Format" },
}

--- Auth schemes for Authorization header
M.auth_schemes = {
  { name = "Bearer ", insert_text = "Bearer ", doc = "OAuth 2.0 Bearer Token authentication: `Bearer <token>`" },
  { name = "Basic ", insert_text = "Basic ", doc = "HTTP Basic authentication: `Basic <base64(user:password)>`" },
  { name = "Digest ", insert_text = "Digest ", doc = "HTTP Digest authentication: `Digest username=...`" },
}

--- Built-in Dynamic Variables
M.dynamic_vars = {
  {
    name = "$uuid",
    insert_text = "$uuid",
    detail = "Dynamic UUID v4",
    doc = "**{{$uuid}}**\n\nGenerates a random RFC 4122 v4 UUID string.\n\n*Example*: `3c2f1f4b-84a1-4328-86d7-313d42b4ecfa`",
  },
  {
    name = "$timestamp",
    insert_text = "$timestamp",
    detail = "Dynamic Unix timestamp",
    doc = "**{{$timestamp}}**\n\nGenerates the current Unix timestamp in seconds.\n\n*Example*: `1700000000`",
  },
  {
    name = "$isoTimestamp",
    insert_text = "$isoTimestamp",
    detail = "Dynamic ISO-8601 UTC timestamp",
    doc = "**{{$isoTimestamp}}**\n\nGenerates the current UTC timestamp in ISO-8601 format.\n\n*Example*: `2026-10-28T22:30:00.000Z`",
  },
  {
    name = "$date",
    insert_text = "$date",
    detail = "Dynamic date (YYYY-MM-DD)",
    doc = "**{{$date}}**\n\nGenerates the current local date formatted as `YYYY-MM-DD`.\n\n*Example*: `2026-10-28`",
  },
  {
    name = "$randomInt",
    insert_text = "$randomInt",
    detail = "Dynamic random integer",
    doc = "**{{$randomInt [min] [max]}}**\n\nGenerates a random integer. Defaults to 0..1000, or accepts custom bounds.\n\n*Example*: `{{$randomInt 100 999}}` -> `482`",
  },
}

--- Directives & Metadata
M.directives = {
  {
    name = "@name",
    insert_text = "@name ",
    detail = "Name request for chaining",
    doc = "# @name <identifier>\n\nAssigns a unique identifier to this request block, allowing subsequent requests to access its response headers, cookies, and body via `{{identifier.response.body.$.path}}`.",
  },
  {
    name = "@env-json-key",
    insert_text = "@env-json-key ",
    detail = "Export JSON response field to env",
    doc = "# @env-json-key <variable> = <jsonpath>\n\nExtracts a field from the JSON response body and exports it into the session environment so subsequent requests can consume `{{variable}}`.",
  },
  {
    name = "@env-header-key",
    insert_text = "@env-header-key ",
    detail = "Export header to env",
    doc = "# @env-header-key <variable> = <header_name>\n\nExtracts an HTTP response header and exports it into the session environment so subsequent requests can consume `{{variable}}`.",
  },
  {
    name = "@prompt",
    insert_text = "@prompt ",
    detail = "Interactive variable prompt",
    doc = "# @prompt <variable> [prompt_message]\n\nPrompts the user interactively in Neovim before sending the request and substitutes the response into `{{variable}}`.",
  },
  {
    name = "@secret",
    insert_text = "@secret ",
    detail = "Masked interactive secret prompt",
    doc = "# @secret <variable> [prompt_message]\n\nPrompts the user interactively with a masked password input before running the request. Never stored on disk.",
  },
  {
    name = "@jq",
    insert_text = "@jq ",
    detail = "Transform response body with jq",
    doc = "# @jq <filter>\n\nFilters and formats the response body using the specified `jq` filter expression.",
  },
  {
    name = "@no-cookie-jar",
    insert_text = "@no-cookie-jar",
    detail = "Disable cookie jar for request",
    doc = "# @no-cookie-jar\n\nDisables automatic cookie persistence and storage for this request.",
  },
  {
    name = "@attach-cookie-jar",
    insert_text = "@attach-cookie-jar ",
    detail = "Attach custom cookie jar file",
    doc = "# @attach-cookie-jar <path>\n\nUses a specific Netscape cookie file for this request instead of the session default.",
  },
  {
    name = "@curl-location",
    insert_text = "@curl-location",
    detail = "cURL --location (follow redirects)",
    doc = "# @curl-location\n\nInstructs cURL to follow HTTP 3xx redirects (`-L` / `--location`).",
  },
  {
    name = "@curl-insecure",
    insert_text = "@curl-insecure",
    detail = "cURL --insecure (skip SSL verify)",
    doc = "# @curl-insecure\n\nInstructs cURL to allow insecure SSL connections without verifying certificates (`-k` / `--insecure`).",
  },
  {
    name = "@curl-compressed",
    insert_text = "@curl-compressed",
    detail = "cURL --compressed",
    doc = "# @curl-compressed\n\nRequests compressed response from the server using gzip/deflate (`--compressed`).",
  },
  {
    name = "@curl-connect-timeout",
    insert_text = "@curl-connect-timeout ",
    detail = "cURL --connect-timeout <seconds>",
    doc = "# @curl-connect-timeout <seconds>\n\nMaximum time in seconds allowed for connection to server.",
  },
  {
    name = "@curl-max-time",
    insert_text = "@curl-max-time ",
    detail = "cURL --max-time <seconds>",
    doc = "# @curl-max-time <seconds>\n\nMaximum time in seconds allowed for the entire transfer.",
  },
  {
    name = "@curl-user-agent",
    insert_text = "@curl-user-agent ",
    detail = "cURL --user-agent <string>",
    doc = "# @curl-user-agent <agent>\n\nOverrides the User-Agent header passed by cURL (`-A`).",
  },
  {
    name = "@curl-proxy",
    insert_text = "@curl-proxy ",
    detail = "cURL --proxy <protocol://host:port>",
    doc = "# @curl-proxy <proxy_url>\n\nRoutes the request through the specified HTTP/HTTPS/SOCKS proxy (`-x`).",
  },
  {
    name = "@curl-verbose",
    insert_text = "@curl-verbose",
    detail = "cURL --verbose",
    doc = "# @curl-verbose\n\nMakes cURL verbose during execution, printing TLS handshake and connection details to Verbose tab.",
  },
}

return M
