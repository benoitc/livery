# NIF Makefile for livery HTTP parser
#
# Builds livery_h1_parse_nif.so using picohttpparser

UNAME_SYS := $(shell uname -s)

# Erlang paths
ERL_INCLUDE := $(shell erl -eval 'io:format("~s", [code:root_dir()]),halt().' -noshell)/usr/include
ERTS_INCLUDE := $(shell erl -eval 'io:format("~s", [code:lib_dir(erts,include)]),halt().' -noshell)

# Compiler flags
CC ?= cc
CFLAGS = -O3 -fPIC -Wall -Wextra -I$(ERL_INCLUDE) -I$(ERTS_INCLUDE)
LDFLAGS = -shared

ifeq ($(UNAME_SYS), Darwin)
	LDFLAGS += -undefined dynamic_lookup -flat_namespace
endif

ifeq ($(UNAME_SYS), Linux)
	CFLAGS += -D_GNU_SOURCE
endif

# Output
PRIV_DIR = ../priv
NIF_SO = $(PRIV_DIR)/livery_h1_parse_nif.so

# Sources
SRCS = livery_h1_parse_nif.c picohttpparser.c
OBJS = $(SRCS:.c=.o)

.PHONY: all clean

all: $(NIF_SO)

$(NIF_SO): $(OBJS) | $(PRIV_DIR)
	$(CC) $(LDFLAGS) -o $@ $(OBJS)

$(PRIV_DIR):
	mkdir -p $(PRIV_DIR)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS) $(NIF_SO)

# Dependencies
livery_h1_parse_nif.o: livery_h1_parse_nif.c picohttpparser.h
picohttpparser.o: picohttpparser.c picohttpparser.h
