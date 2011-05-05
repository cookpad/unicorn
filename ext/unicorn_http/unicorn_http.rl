/**
 * Copyright (c) 2009 Eric Wong (all bugs are Eric's fault)
 * Copyright (c) 2005 Zed A. Shaw
 * You can redistribute it and/or modify it under the same terms as Ruby.
 */
#include "ruby.h"
#include "ext_help.h"
#include <assert.h>
#include <string.h>
#include <sys/types.h>
#include "common_field_optimization.h"
#include "global_variables.h"
#include "c_util.h"

void init_unicorn_httpdate(void);

#define UH_FL_CHUNKED  0x1
#define UH_FL_HASBODY  0x2
#define UH_FL_INBODY   0x4
#define UH_FL_HASTRAILER 0x8
#define UH_FL_INTRAILER 0x10
#define UH_FL_INCHUNK  0x20
#define UH_FL_REQEOF 0x40
#define UH_FL_KAVERSION 0x80
#define UH_FL_HASHEADER 0x100
#define UH_FL_TO_CLEAR 0x200

/* all of these flags need to be set for keepalive to be supported */
#define UH_FL_KEEPALIVE (UH_FL_KAVERSION | UH_FL_REQEOF | UH_FL_HASHEADER)

/*
 * whether or not to trust X-Forwarded-Proto and X-Forwarded-SSL when
 * setting rack.url_scheme
 */
static VALUE trust_x_forward = Qtrue;

static unsigned long keepalive_requests = 100; /* same as nginx */

/*
 * Returns the maximum number of keepalive requests a client may make
 * before the parser refuses to continue.
 */
static VALUE ka_req(VALUE self)
{
  return ULONG2NUM(keepalive_requests);
}

/*
 * Sets the maximum number of keepalive requests a client may make.
 * A special value of +nil+ causes this to be the maximum value
 * possible (this is architecture-dependent).
 */
static VALUE set_ka_req(VALUE self, VALUE val)
{
  keepalive_requests = NIL_P(val) ? ULONG_MAX : NUM2ULONG(val);

  return ka_req(self);
}

/*
 * Sets whether or not the parser will trust X-Forwarded-Proto and
 * X-Forwarded-SSL headers and set "rack.url_scheme" to "https" accordingly.
 * Rainbows!/Zbatery installations facing untrusted clients directly
 * should set this to +false+
 */
static VALUE set_xftrust(VALUE self, VALUE val)
{
  if (Qtrue == val || Qfalse == val)
    trust_x_forward = val;
  else
    rb_raise(rb_eTypeError, "must be true or false");

  return val;
}

/*
 * returns whether or not the parser will trust X-Forwarded-Proto and
 * X-Forwarded-SSL headers and set "rack.url_scheme" to "https" accordingly
 */
static VALUE xftrust(VALUE self)
{
  return trust_x_forward;
}

static size_t MAX_HEADER_LEN = 1024 * (80 + 32); /* same as Mongrel */

/* this is only intended for use with Rainbows! */
static VALUE set_maxhdrlen(VALUE self, VALUE len)
{
  return SIZET2NUM(MAX_HEADER_LEN = NUM2SIZET(len));
}

/* keep this small for Rainbows! since every client has one */
struct http_parser {
  int cs; /* Ragel internal state */
  unsigned int flags;
  unsigned long nr_requests;
  size_t mark;
  size_t offset;
  union { /* these 2 fields don't nest */
    size_t field;
    size_t query;
  } start;
  union {
    size_t field_len; /* only used during header processing */
    size_t dest_offset; /* only used during body processing */
  } s;
  VALUE buf;
  VALUE env;
  VALUE cont; /* Qfalse: unset, Qnil: ignored header, T_STRING: append */
  union {
    off_t content;
    off_t chunk;
  } len;
};

static ID id_clear, id_set_backtrace;

static void finalize_header(struct http_parser *hp);

static void parser_raise(VALUE klass, const char *msg)
{
  VALUE exc = rb_exc_new2(klass, msg);
  VALUE bt = rb_ary_new();

	rb_funcall(exc, id_set_backtrace, 1, bt);
	rb_exc_raise(exc);
}

#define REMAINING (unsigned long)(pe - p)
#define LEN(AT, FPC) (FPC - buffer - hp->AT)
#define MARK(M,FPC) (hp->M = (FPC) - buffer)
#define PTR_TO(F) (buffer + hp->F)
#define STR_NEW(M,FPC) rb_str_new(PTR_TO(M), LEN(M, FPC))

#define HP_FL_TEST(hp,fl) ((hp)->flags & (UH_FL_##fl))
#define HP_FL_SET(hp,fl) ((hp)->flags |= (UH_FL_##fl))
#define HP_FL_UNSET(hp,fl) ((hp)->flags &= ~(UH_FL_##fl))
#define HP_FL_ALL(hp,fl) (HP_FL_TEST(hp, fl) == (UH_FL_##fl))

/*
 * handles values of the "Connection:" header, keepalive is implied
 * for HTTP/1.1 but needs to be explicitly enabled with HTTP/1.0
 * Additionally, we require GET/HEAD requests to support keepalive.
 */
static void hp_keepalive_connection(struct http_parser *hp, VALUE val)
{
  if (STR_CSTR_CASE_EQ(val, "keep-alive")) {
    /* basically have HTTP/1.0 masquerade as HTTP/1.1+ */
    HP_FL_SET(hp, KAVERSION);
  } else if (STR_CSTR_CASE_EQ(val, "close")) {
    /*
     * it doesn't matter what HTTP version or request method we have,
     * if a client says "Connection: close", we disable keepalive
     */
    HP_FL_UNSET(hp, KAVERSION);
  } else {
    /*
     * client could've sent anything, ignore it for now.  Maybe
     * "HP_FL_UNSET(hp, KAVERSION);" just in case?
     * Raising an exception might be too mean...
     */
  }
}

static void
request_method(struct http_parser *hp, const char *ptr, size_t len)
{
  VALUE v = rb_str_new(ptr, len);

  rb_hash_aset(hp->env, g_request_method, v);
}

static void
http_version(struct http_parser *hp, const char *ptr, size_t len)
{
  VALUE v;

  HP_FL_SET(hp, HASHEADER);

  if (CONST_MEM_EQ("HTTP/1.1", ptr, len)) {
    /* HTTP/1.1 implies keepalive unless "Connection: close" is set */
    HP_FL_SET(hp, KAVERSION);
    v = g_http_11;
  } else if (CONST_MEM_EQ("HTTP/1.0", ptr, len)) {
    v = g_http_10;
  } else {
    v = rb_str_new(ptr, len);
  }
  rb_hash_aset(hp->env, g_server_protocol, v);
  rb_hash_aset(hp->env, g_http_version, v);
}

static inline void hp_invalid_if_trailer(struct http_parser *hp)
{
  if (HP_FL_TEST(hp, INTRAILER))
    parser_raise(eHttpParserError, "invalid Trailer");
}

static void write_cont_value(struct http_parser *hp,
                             char *buffer, const char *p)
{
  char *vptr;

  if (hp->cont == Qfalse)
     parser_raise(eHttpParserError, "invalid continuation line");
  if (NIL_P(hp->cont))
     return; /* we're ignoring this header (probably Host:) */

  assert(TYPE(hp->cont) == T_STRING && "continuation line is not a string");
  assert(hp->mark > 0 && "impossible continuation line offset");

  if (LEN(mark, p) == 0)
    return;

  if (RSTRING_LEN(hp->cont) > 0)
    --hp->mark;

  vptr = PTR_TO(mark);

  if (RSTRING_LEN(hp->cont) > 0) {
    assert((' ' == *vptr || '\t' == *vptr) && "invalid leading white space");
    *vptr = ' ';
  }
  rb_str_buf_cat(hp->cont, vptr, LEN(mark, p));
}

static void write_value(struct http_parser *hp,
                        const char *buffer, const char *p)
{
  VALUE f = find_common_field(PTR_TO(start.field), hp->s.field_len);
  VALUE v;
  VALUE e;

  VALIDATE_MAX_LENGTH(LEN(mark, p), FIELD_VALUE);
  v = LEN(mark, p) == 0 ? rb_str_buf_new(128) : STR_NEW(mark, p);
  if (NIL_P(f)) {
    const char *field = PTR_TO(start.field);
    size_t flen = hp->s.field_len;

    VALIDATE_MAX_LENGTH(flen, FIELD_NAME);

    /*
     * ignore "Version" headers since they conflict with the HTTP_VERSION
     * rack env variable.
     */
    if (CONST_MEM_EQ("VERSION", field, flen)) {
      hp->cont = Qnil;
      return;
    }
    f = uncommon_field(field, flen);
  } else if (f == g_http_connection) {
    hp_keepalive_connection(hp, v);
  } else if (f == g_content_length) {
    hp->len.content = parse_length(RSTRING_PTR(v), RSTRING_LEN(v));
    if (hp->len.content < 0)
      parser_raise(eHttpParserError, "invalid Content-Length");
    if (hp->len.content != 0)
      HP_FL_SET(hp, HASBODY);
    hp_invalid_if_trailer(hp);
  } else if (f == g_http_transfer_encoding) {
    if (STR_CSTR_CASE_EQ(v, "chunked")) {
      HP_FL_SET(hp, CHUNKED);
      HP_FL_SET(hp, HASBODY);
    }
    hp_invalid_if_trailer(hp);
  } else if (f == g_http_trailer) {
    HP_FL_SET(hp, HASTRAILER);
    hp_invalid_if_trailer(hp);
  } else {
    assert(TYPE(f) == T_STRING && "memoized object is not a string");
    assert_frozen(f);
  }

  e = rb_hash_aref(hp->env, f);
  if (NIL_P(e)) {
    hp->cont = rb_hash_aset(hp->env, f, v);
  } else if (f == g_http_host) {
    /*
     * ignored, absolute URLs in REQUEST_URI take precedence over
     * the Host: header (ref: rfc 2616, section 5.2.1)
     */
     hp->cont = Qnil;
  } else {
    rb_str_buf_cat(e, ",", 1);
    hp->cont = rb_str_buf_append(e, v);
  }
}

/** Machine **/

%%{
  machine http_parser;

  action mark {MARK(mark, fpc); }

  action start_field { MARK(start.field, fpc); }
  action snake_upcase_field { snake_upcase_char(deconst(fpc)); }
  action downcase_char { downcase_char(deconst(fpc)); }
  action write_field { hp->s.field_len = LEN(start.field, fpc); }
  action start_value { MARK(mark, fpc); }
  action write_value { write_value(hp, buffer, fpc); }
  action write_cont_value { write_cont_value(hp, buffer, fpc); }
  action request_method { request_method(hp, PTR_TO(mark), LEN(mark, fpc)); }
  action scheme {
    rb_hash_aset(hp->env, g_rack_url_scheme, STR_NEW(mark, fpc));
  }
  action host { rb_hash_aset(hp->env, g_http_host, STR_NEW(mark, fpc)); }
  action request_uri {
    VALUE str;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, fpc), REQUEST_URI);
    str = rb_hash_aset(hp->env, g_request_uri, STR_NEW(mark, fpc));
    /*
     * "OPTIONS * HTTP/1.1\r\n" is a valid request, but we can't have '*'
     * in REQUEST_PATH or PATH_INFO or else Rack::Lint will complain
     */
    if (STR_CSTR_EQ(str, "*")) {
      str = rb_str_new(NULL, 0);
      rb_hash_aset(hp->env, g_path_info, str);
      rb_hash_aset(hp->env, g_request_path, str);
    }
  }
  action fragment {
    VALIDATE_MAX_URI_LENGTH(LEN(mark, fpc), FRAGMENT);
    rb_hash_aset(hp->env, g_fragment, STR_NEW(mark, fpc));
  }
  action start_query {MARK(start.query, fpc); }
  action query_string {
    VALIDATE_MAX_URI_LENGTH(LEN(start.query, fpc), QUERY_STRING);
    rb_hash_aset(hp->env, g_query_string, STR_NEW(start.query, fpc));
  }
  action http_version { http_version(hp, PTR_TO(mark), LEN(mark, fpc)); }
  action request_path {
    VALUE val;

    VALIDATE_MAX_URI_LENGTH(LEN(mark, fpc), REQUEST_PATH);
    val = rb_hash_aset(hp->env, g_request_path, STR_NEW(mark, fpc));

    /* rack says PATH_INFO must start with "/" or be empty */
    if (!STR_CSTR_EQ(val, "*"))
      rb_hash_aset(hp->env, g_path_info, val);
  }
  action add_to_chunk_size {
    hp->len.chunk = step_incr(hp->len.chunk, fc, 16);
    if (hp->len.chunk < 0)
      parser_raise(eHttpParserError, "invalid chunk size");
  }
  action header_done {
    finalize_header(hp);

    cs = http_parser_first_final;
    if (HP_FL_TEST(hp, HASBODY)) {
      HP_FL_SET(hp, INBODY);
      if (HP_FL_TEST(hp, CHUNKED))
        cs = http_parser_en_ChunkedBody;
    } else {
      HP_FL_SET(hp, REQEOF);
      assert(!HP_FL_TEST(hp, CHUNKED) && "chunked encoding without body!");
    }
    /*
     * go back to Ruby so we can call the Rack application, we'll reenter
     * the parser iff the body needs to be processed.
     */
    goto post_exec;
  }

  action end_trailers {
    cs = http_parser_first_final;
    goto post_exec;
  }

  action end_chunked_body {
    HP_FL_SET(hp, INTRAILER);
    cs = http_parser_en_Trailers;
    ++p;
    assert(p <= pe && "buffer overflow after chunked body");
    goto post_exec;
  }

  action skip_chunk_data {
  skip_chunk_data_hack: {
    size_t nr = MIN((size_t)hp->len.chunk, REMAINING);
    memcpy(RSTRING_PTR(hp->cont) + hp->s.dest_offset, fpc, nr);
    hp->s.dest_offset += nr;
    hp->len.chunk -= nr;
    p += nr;
    assert(hp->len.chunk >= 0 && "negative chunk length");
    if ((size_t)hp->len.chunk > REMAINING) {
      HP_FL_SET(hp, INCHUNK);
      goto post_exec;
    } else {
      fhold;
      fgoto chunk_end;
    }
  }}

  include unicorn_http_common "unicorn_http_common.rl";
}%%

/** Data **/
%% write data;

static void http_parser_init(struct http_parser *hp)
{
  int cs = 0;
  hp->flags = 0;
  hp->mark = 0;
  hp->offset = 0;
  hp->start.field = 0;
  hp->s.field_len = 0;
  hp->len.content = 0;
  hp->cont = Qfalse; /* zero on MRI, should be optimized away by above */
  %% write init;
  hp->cs = cs;
}

/** exec **/
static void
http_parser_execute(struct http_parser *hp, char *buffer, size_t len)
{
  const char *p, *pe;
  int cs = hp->cs;
  size_t off = hp->offset;

  if (cs == http_parser_first_final)
    return;

  assert(off <= len && "offset past end of buffer");

  p = buffer+off;
  pe = buffer+len;

  assert((void *)(pe - p) == (void *)(len - off) &&
         "pointers aren't same distance");

  if (HP_FL_TEST(hp, INCHUNK)) {
    HP_FL_UNSET(hp, INCHUNK);
    goto skip_chunk_data_hack;
  }
  %% write exec;
post_exec: /* "_out:" also goes here */
  if (hp->cs != http_parser_error)
    hp->cs = cs;
  hp->offset = p - buffer;

  assert(p <= pe && "buffer overflow after parsing execute");
  assert(hp->offset <= len && "offset longer than length");
}

static struct http_parser *data_get(VALUE self)
{
  struct http_parser *hp;

  Data_Get_Struct(self, struct http_parser, hp);
  assert(hp && "failed to extract http_parser struct");
  return hp;
}

/*
 * set rack.url_scheme to "https" or "http", no others are allowed by Rack
 * this resembles the Rack::Request#scheme method as of rack commit
 * 35bb5ba6746b5d346de9202c004cc926039650c7
 */
static void set_url_scheme(VALUE env, VALUE *server_port)
{
  VALUE scheme = rb_hash_aref(env, g_rack_url_scheme);

  if (NIL_P(scheme)) {
    if (trust_x_forward == Qfalse) {
      scheme = g_http;
    } else {
      scheme = rb_hash_aref(env, g_http_x_forwarded_ssl);
      if (!NIL_P(scheme) && STR_CSTR_EQ(scheme, "on")) {
        *server_port = g_port_443;
        scheme = g_https;
      } else {
        scheme = rb_hash_aref(env, g_http_x_forwarded_proto);
        if (NIL_P(scheme)) {
          scheme = g_http;
        } else {
          long len = RSTRING_LEN(scheme);
          if (len >= 5 && !memcmp(RSTRING_PTR(scheme), "https", 5)) {
            if (len != 5)
              scheme = g_https;
            *server_port = g_port_443;
          } else {
            scheme = g_http;
          }
        }
      }
    }
    rb_hash_aset(env, g_rack_url_scheme, scheme);
  } else if (STR_CSTR_EQ(scheme, "https")) {
    *server_port = g_port_443;
  } else {
    assert(*server_port == g_port_80 && "server_port not set");
  }
}

/*
 * Parse and set the SERVER_NAME and SERVER_PORT variables
 * Not supporting X-Forwarded-Host/X-Forwarded-Port in here since
 * anybody who needs them is using an unsupported configuration and/or
 * incompetent.  Rack::Request will handle X-Forwarded-{Port,Host} just
 * fine.
 */
static void set_server_vars(VALUE env, VALUE *server_port)
{
  VALUE server_name = g_localhost;
  VALUE host = rb_hash_aref(env, g_http_host);

  if (!NIL_P(host)) {
    char *host_ptr = RSTRING_PTR(host);
    long host_len = RSTRING_LEN(host);
    char *colon;

    if (*host_ptr == '[') { /* ipv6 address format */
      char *rbracket = memchr(host_ptr + 1, ']', host_len - 1);

      if (rbracket)
        colon = (rbracket[1] == ':') ? rbracket + 1 : NULL;
      else
        colon = memchr(host_ptr + 1, ':', host_len - 1);
    } else {
      colon = memchr(host_ptr, ':', host_len);
    }

    if (colon) {
      long port_start = colon - host_ptr + 1;

      server_name = rb_str_substr(host, 0, colon - host_ptr);
      if ((host_len - port_start) > 0)
        *server_port = rb_str_substr(host, port_start, host_len);
    } else {
      server_name = host;
    }
  }
  rb_hash_aset(env, g_server_name, server_name);
  rb_hash_aset(env, g_server_port, *server_port);
}

static void finalize_header(struct http_parser *hp)
{
  VALUE server_port = g_port_80;

  set_url_scheme(hp->env, &server_port);
  set_server_vars(hp->env, &server_port);

  if (!HP_FL_TEST(hp, HASHEADER))
    rb_hash_aset(hp->env, g_server_protocol, g_http_09);

  /* rack requires QUERY_STRING */
  if (NIL_P(rb_hash_aref(hp->env, g_query_string)))
    rb_hash_aset(hp->env, g_query_string, rb_str_new(NULL, 0));
}

static void hp_mark(void *ptr)
{
  struct http_parser *hp = ptr;

  rb_gc_mark(hp->buf);
  rb_gc_mark(hp->env);
  rb_gc_mark(hp->cont);
}

static VALUE HttpParser_alloc(VALUE klass)
{
  struct http_parser *hp;
  return Data_Make_Struct(klass, struct http_parser, hp_mark, -1, hp);
}


/**
 * call-seq:
 *    parser.new => parser
 *
 * Creates a new parser.
 */
static VALUE HttpParser_init(VALUE self)
{
  struct http_parser *hp = data_get(self);

  http_parser_init(hp);
  hp->buf = rb_str_new(NULL, 0);
  hp->env = rb_hash_new();
  hp->nr_requests = keepalive_requests;

  return self;
}

/**
 * call-seq:
 *    parser.clear => parser
 *
 * Resets the parser to it's initial state so that you can reuse it
 * rather than making new ones.
 */
static VALUE HttpParser_clear(VALUE self)
{
  struct http_parser *hp = data_get(self);

  http_parser_init(hp);
  rb_funcall(hp->env, id_clear, 0);

  return self;
}

/**
 * call-seq:
 *    parser.reset => nil
 *
 * Resets the parser to it's initial state so that you can reuse it
 * rather than making new ones.
 *
 * This method is deprecated and to be removed in Unicorn 4.x
 */
static VALUE HttpParser_reset(VALUE self)
{
  static int warned;

  if (!warned) {
    rb_warn("Unicorn::HttpParser#reset is deprecated; "
            "use Unicorn::HttpParser#clear instead");
  }
  HttpParser_clear(self);
  return Qnil;
}

static void advance_str(VALUE str, off_t nr)
{
  long len = RSTRING_LEN(str);

  if (len == 0)
    return;

  rb_str_modify(str);

  assert(nr <= len && "trying to advance past end of buffer");
  len -= nr;
  if (len > 0) /* unlikely, len is usually 0 */
    memmove(RSTRING_PTR(str), RSTRING_PTR(str) + nr, len);
  rb_str_set_len(str, len);
}

/**
 * call-seq:
 *   parser.content_length => nil or Integer
 *
 * Returns the number of bytes left to run through HttpParser#filter_body.
 * This will initially be the value of the "Content-Length" HTTP header
 * after header parsing is complete and will decrease in value as
 * HttpParser#filter_body is called for each chunk.  This should return
 * zero for requests with no body.
 *
 * This will return nil on "Transfer-Encoding: chunked" requests.
 */
static VALUE HttpParser_content_length(VALUE self)
{
  struct http_parser *hp = data_get(self);

  return HP_FL_TEST(hp, CHUNKED) ? Qnil : OFFT2NUM(hp->len.content);
}

/**
 * Document-method: parse
 * call-seq:
 *    parser.parse => env or nil
 *
 * Takes a Hash and a String of data, parses the String of data filling
 * in the Hash returning the Hash if parsing is finished, nil otherwise
 * When returning the env Hash, it may modify data to point to where
 * body processing should begin.
 *
 * Raises HttpParserError if there are parsing errors.
 */
static VALUE HttpParser_parse(VALUE self)
{
  struct http_parser *hp = data_get(self);
  VALUE data = hp->buf;

  if (HP_FL_TEST(hp, TO_CLEAR)) {
    http_parser_init(hp);
    rb_funcall(hp->env, id_clear, 0);
  }

  http_parser_execute(hp, RSTRING_PTR(data), RSTRING_LEN(data));
  if (hp->offset > MAX_HEADER_LEN)
    parser_raise(e413, "HTTP header is too large");

  if (hp->cs == http_parser_first_final ||
      hp->cs == http_parser_en_ChunkedBody) {
    advance_str(data, hp->offset + 1);
    hp->offset = 0;
    if (HP_FL_TEST(hp, INTRAILER))
      HP_FL_SET(hp, REQEOF);

    return hp->env;
  }

  if (hp->cs == http_parser_error)
    parser_raise(eHttpParserError, "Invalid HTTP format, parsing fails.");

  return Qnil;
}

/**
 * Document-method: parse
 * call-seq:
 *    parser.add_parse(buffer) => env or nil
 *
 * adds the contents of +buffer+ to the internal buffer and attempts to
 * continue parsing.  Returns the +env+ Hash on success or nil if more
 * data is needed.
 *
 * Raises HttpParserError if there are parsing errors.
 */
static VALUE HttpParser_add_parse(VALUE self, VALUE buffer)
{
  struct http_parser *hp = data_get(self);

  Check_Type(buffer, T_STRING);
  rb_str_buf_append(hp->buf, buffer);

  return HttpParser_parse(self);
}

/**
 * Document-method: trailers
 * call-seq:
 *    parser.trailers(req, data) => req or nil
 *
 * This is an alias for HttpParser#headers
 */

/**
 * Document-method: headers
 */
static VALUE HttpParser_headers(VALUE self, VALUE env, VALUE buf)
{
  struct http_parser *hp = data_get(self);

  hp->env = env;
  hp->buf = buf;

  return HttpParser_parse(self);
}

static int chunked_eof(struct http_parser *hp)
{
  return ((hp->cs == http_parser_first_final) || HP_FL_TEST(hp, INTRAILER));
}

/**
 * call-seq:
 *    parser.body_eof? => true or false
 *
 * Detects if we're done filtering the body or not.  This can be used
 * to detect when to stop calling HttpParser#filter_body.
 */
static VALUE HttpParser_body_eof(VALUE self)
{
  struct http_parser *hp = data_get(self);

  if (HP_FL_TEST(hp, CHUNKED))
    return chunked_eof(hp) ? Qtrue : Qfalse;

  return hp->len.content == 0 ? Qtrue : Qfalse;
}

/**
 * call-seq:
 *    parser.keepalive? => true or false
 *
 * This should be used to detect if a request can really handle
 * keepalives and pipelining.  Currently, the rules are:
 *
 * 1. MUST be a GET or HEAD request
 * 2. MUST be HTTP/1.1 +or+ HTTP/1.0 with "Connection: keep-alive"
 * 3. MUST NOT have "Connection: close" set
 */
static VALUE HttpParser_keepalive(VALUE self)
{
  struct http_parser *hp = data_get(self);

  return HP_FL_ALL(hp, KEEPALIVE) ? Qtrue : Qfalse;
}

/**
 * call-seq:
 *    parser.next? => true or false
 *
 * Exactly like HttpParser#keepalive?, except it will reset the internal
 * parser state on next parse if it returns true.  It will also respect
 * the maximum *keepalive_requests* value and return false if that is
 * reached.
 */
static VALUE HttpParser_next(VALUE self)
{
  struct http_parser *hp = data_get(self);

  if ((HP_FL_ALL(hp, KEEPALIVE)) && (hp->nr_requests-- != 0)) {
    HP_FL_SET(hp, TO_CLEAR);
    return Qtrue;
  }
  return Qfalse;
}

/**
 * call-seq:
 *    parser.headers? => true or false
 *
 * This should be used to detect if a request has headers (and if
 * the response will have headers as well).  HTTP/0.9 requests
 * should return false, all subsequent HTTP versions will return true
 */
static VALUE HttpParser_has_headers(VALUE self)
{
  struct http_parser *hp = data_get(self);

  return HP_FL_TEST(hp, HASHEADER) ? Qtrue : Qfalse;
}

static VALUE HttpParser_buf(VALUE self)
{
  return data_get(self)->buf;
}

static VALUE HttpParser_env(VALUE self)
{
  return data_get(self)->env;
}

/**
 * call-seq:
 *    parser.filter_body(buf, data) => nil/data
 *
 * Takes a String of +data+, will modify data if dechunking is done.
 * Returns +nil+ if there is more data left to process.  Returns
 * +data+ if body processing is complete. When returning +data+,
 * it may modify +data+ so the start of the string points to where
 * the body ended so that trailer processing can begin.
 *
 * Raises HttpParserError if there are dechunking errors.
 * Basically this is a glorified memcpy(3) that copies +data+
 * into +buf+ while filtering it through the dechunker.
 */
static VALUE HttpParser_filter_body(VALUE self, VALUE buf, VALUE data)
{
  struct http_parser *hp = data_get(self);
  char *dptr;
  long dlen;

  dptr = RSTRING_PTR(data);
  dlen = RSTRING_LEN(data);

  StringValue(buf);
  rb_str_resize(buf, dlen); /* we can never copy more than dlen bytes */
  OBJ_TAINT(buf); /* keep weirdo $SAFE users happy */

  if (HP_FL_TEST(hp, CHUNKED)) {
    if (!chunked_eof(hp)) {
      hp->s.dest_offset = 0;
      hp->cont = buf;
      hp->buf = data;
      http_parser_execute(hp, dptr, dlen);
      if (hp->cs == http_parser_error)
        parser_raise(eHttpParserError, "Invalid HTTP format, parsing fails.");

      assert(hp->s.dest_offset <= hp->offset &&
             "destination buffer overflow");
      advance_str(data, hp->offset);
      rb_str_set_len(buf, hp->s.dest_offset);

      if (RSTRING_LEN(buf) == 0 && chunked_eof(hp)) {
        assert(hp->len.chunk == 0 && "chunk at EOF but more to parse");
      } else {
        data = Qnil;
      }
    }
  } else {
    /* no need to enter the Ragel machine for unchunked transfers */
    assert(hp->len.content >= 0 && "negative Content-Length");
    if (hp->len.content > 0) {
      long nr = MIN(dlen, hp->len.content);

      hp->buf = data;
      memcpy(RSTRING_PTR(buf), dptr, nr);
      hp->len.content -= nr;
      if (hp->len.content == 0) {
        HP_FL_SET(hp, REQEOF);
        hp->cs = http_parser_first_final;
      }
      advance_str(data, nr);
      rb_str_set_len(buf, nr);
      data = Qnil;
    }
  }
  hp->offset = 0; /* for trailer parsing */
  return data;
}

#define SET_GLOBAL(var,str) do { \
  var = find_common_field(str, sizeof(str) - 1); \
  assert(!NIL_P(var) && "missed global field"); \
} while (0)

void Init_unicorn_http(void)
{
  VALUE mUnicorn, cHttpParser;

  mUnicorn = rb_const_get(rb_cObject, rb_intern("Unicorn"));
  cHttpParser = rb_define_class_under(mUnicorn, "HttpParser", rb_cObject);
  eHttpParserError =
         rb_define_class_under(mUnicorn, "HttpParserError", rb_eIOError);
  e413 = rb_define_class_under(mUnicorn, "RequestEntityTooLargeError",
                               eHttpParserError);
  e414 = rb_define_class_under(mUnicorn, "RequestURITooLongError",
                               eHttpParserError);

  init_globals();
  rb_define_alloc_func(cHttpParser, HttpParser_alloc);
  rb_define_method(cHttpParser, "initialize", HttpParser_init, 0);
  rb_define_method(cHttpParser, "clear", HttpParser_clear, 0);
  rb_define_method(cHttpParser, "reset", HttpParser_reset, 0);
  rb_define_method(cHttpParser, "parse", HttpParser_parse, 0);
  rb_define_method(cHttpParser, "add_parse", HttpParser_add_parse, 1);
  rb_define_method(cHttpParser, "headers", HttpParser_headers, 2);
  rb_define_method(cHttpParser, "trailers", HttpParser_headers, 2);
  rb_define_method(cHttpParser, "filter_body", HttpParser_filter_body, 2);
  rb_define_method(cHttpParser, "content_length", HttpParser_content_length, 0);
  rb_define_method(cHttpParser, "body_eof?", HttpParser_body_eof, 0);
  rb_define_method(cHttpParser, "keepalive?", HttpParser_keepalive, 0);
  rb_define_method(cHttpParser, "headers?", HttpParser_has_headers, 0);
  rb_define_method(cHttpParser, "next?", HttpParser_next, 0);
  rb_define_method(cHttpParser, "buf", HttpParser_buf, 0);
  rb_define_method(cHttpParser, "env", HttpParser_env, 0);

  /*
   * The maximum size a single chunk when using chunked transfer encoding.
   * This is only a theoretical maximum used to detect errors in clients,
   * it is highly unlikely to encounter clients that send more than
   * several kilobytes at once.
   */
  rb_define_const(cHttpParser, "CHUNK_MAX", OFFT2NUM(UH_OFF_T_MAX));

  /*
   * The maximum size of the body as specified by Content-Length.
   * This is only a theoretical maximum, the actual limit is subject
   * to the limits of the file system used for +Dir.tmpdir+.
   */
  rb_define_const(cHttpParser, "LENGTH_MAX", OFFT2NUM(UH_OFF_T_MAX));

  /* default value for keepalive_requests */
  rb_define_const(cHttpParser, "KEEPALIVE_REQUESTS_DEFAULT",
                  ULONG2NUM(keepalive_requests));

  rb_define_singleton_method(cHttpParser, "keepalive_requests", ka_req, 0);
  rb_define_singleton_method(cHttpParser, "keepalive_requests=", set_ka_req, 1);
  rb_define_singleton_method(cHttpParser, "trust_x_forwarded=", set_xftrust, 1);
  rb_define_singleton_method(cHttpParser, "trust_x_forwarded?", xftrust, 0);
  rb_define_singleton_method(cHttpParser, "max_header_len=", set_maxhdrlen, 1);

  init_common_fields();
  SET_GLOBAL(g_http_host, "HOST");
  SET_GLOBAL(g_http_trailer, "TRAILER");
  SET_GLOBAL(g_http_transfer_encoding, "TRANSFER_ENCODING");
  SET_GLOBAL(g_content_length, "CONTENT_LENGTH");
  SET_GLOBAL(g_http_connection, "CONNECTION");
  id_clear = rb_intern("clear");
  id_set_backtrace = rb_intern("set_backtrace");
  init_unicorn_httpdate();
}
#undef SET_GLOBAL
