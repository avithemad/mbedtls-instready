#!/usr/bin/env perl
#
# This is a proof-of-concept script to show that the client and server wrappers
# can be created by a script. It is not hooked into the build, so is run
# manually and the output files are what are to be reviewed. In due course
# this will be replaced by a Python script based on the
# code_wrapper.psa_wrapper module.
#
# Copyright The Mbed TLS Contributors
# SPDX-License-Identifier: Apache-2.0 OR GPL-2.0-or-later
#
use strict;
use Data::Dumper;
use File::Basename;
use JSON qw(encode_json);

my $debug = 0;

# Globals (sorry!)
my $output_dir = dirname($0);

my %functions = get_functions();
my @functions = sort keys %functions;

# We don't want these functions (e.g. because they are not implemented, etc)
my @skip_functions = (
    'mbedtls_psa_crypto_free', # redefined rather than wrapped
    'mbedtls_psa_external_get_random', # not in the default config, uses unsupported type
    'mbedtls_psa_get_stats', # uses unsupported type
    'mbedtls_psa_inject_entropy', # not in the default config, generally not for client use anyway
    'mbedtls_psa_platform_get_builtin_key', # not in the default config, uses unsupported type
    'mbedtls_psa_register_se_key', # not in the default config, generally not for client use anyway
    'psa_get_key_slot_number', # not in the default config, uses unsupported type
    'psa_key_derivation_verify_bytes', # not implemented yet
    'psa_key_derivation_verify_key', # not implemented yet
);

my $skip_functions_re = '\A(' . join('|', @skip_functions). ')\Z';
@functions = grep(!/$skip_functions_re
                   |_pake_ # Skip everything PAKE
                   |_init\Z # constructors
                   /x, @functions);
# Restore psa_crypto_init() and put it first.
unshift @functions, 'psa_crypto_init';

# get_functions(), called above, returns a data structure for each function
# that we need to create client and server stubs for. The functions are
# listed from PSA header files.
#
# In this script, the data for psa_crypto_init() looks like:
#
#   "psa_crypto_init": {
#     "return": {               # Info on return type
#       "type": "psa_status_t", # Return type
#       "name": "status",       # Name to be used for this in C code
#       "default": "PSA_ERROR_CORRUPTION_DETECTED"      # Default value
#     },
#     "args": [],               # void function, so args empty
#   }
#
# The data for psa_hash_compute() looks like:
#
#  "psa_hash_compute": {
#    "return": {                # Information on return type
#      "type": "psa_status_t",
#      "name": "status",
#      "default": "PSA_ERROR_CORRUPTION_DETECTED"
#    },
#    "args": [{
#        "type": "psa_algorithm_t",             # Type of first argument
#        "ctypename": "psa_algorithm_t ",       # C type with trailing spaces
#                                               # (so that e.g. `char *` looks ok)
#        "name": "alg",
#        "is_output": 0
#      }, {
#        "type": "const buffer",                # Specially created
#        "ctypename": "",                       # (so no C type)
#        "name": "input, input_length",         # A pair of arguments
#        "is_output": 0                         # const, so not an output argument
#      }, {
#        "type": "buffer",                      # Specially created
#        "ctypename": "",
#        "name": "hash, hash_size",
#        "is_output": 1                         # Not const, so output argument
#      }, {
#        "type": "size_t",                      # size_t *hash_length
#        "ctypename": "size_t ",
#        "name": "*hash_length",                # * comes into the name
#        "is_output": 1
#      }
#    ],
#  },
#
# It's possible that a production version might not need both type and ctypename;
# that was done for convenience and future-proofing during development.

write_function_codes("$output_dir/psa_functions_codes.h");

write_client_calls("$output_dir/psa_sim_crypto_client.c");

write_server_implementations("$output_dir/psa_sim_crypto_server.c");

sub write_function_codes
{
    my ($file) = @_;

    open(my $fh, ">", $file) || die("$0: $file: $!\n");

    # NOTE: psa_crypto_init() is written manually

    print $fh <<EOF;
/* THIS FILE WAS AUTO-GENERATED BY psa_sim_generate.pl. DO NOT EDIT!! */

/*
 *  Copyright The Mbed TLS Contributors
 *  SPDX-License-Identifier: Apache-2.0 OR GPL-2.0-or-later
 */

#ifndef _PSA_FUNCTIONS_CODES_H_
#define  _PSA_FUNCTIONS_CODES_H_

enum {
    /* Start here to avoid overlap with PSA_IPC_CONNECT, PSA_IPC_DISCONNECT
     * and VERSION_REQUEST */
    PSA_CRYPTO_INIT = 100,
EOF

    for my $function (@functions) {
        my $enum = uc($function);
        if ($enum ne "PSA_CRYPTO_INIT") {
            print $fh <<EOF;
    $enum,
EOF
        }
    }

    print $fh <<EOF;
};

#endif /*  _PSA_FUNCTIONS_CODES_H_ */
EOF

    close($fh);
}

sub write_client_calls
{
    my ($file) = @_;

    open(my $fh, ">", $file) || die("$0: $file: $!\n");

    print $fh client_calls_header();

    for my $function (@functions) {
        # psa_crypto_init() is hand written to establish connection to server
        if ($function ne "psa_crypto_init") {
            my $f = $functions{$function};
            output_client($fh, $f, $function);
        }
    }

    close($fh);
}

sub write_server_implementations
{
    my ($file) = @_;

    open(my $fh, ">", $file) || die("$0: $file: $!\n");

    print $fh server_implementations_header();

    print $fh debug_functions() if $debug;

    for my $function (@functions) {
        my $f = $functions{$function};
        output_server_wrapper($fh, $f, $function);
    }

    # Now output a switch statement that calls each of the wrappers

    print $fh <<EOF;

psa_status_t psa_crypto_call(psa_msg_t msg)
{
    int ok = 0;

    int func = msg.type;

    /* We only expect a single input buffer, with everything serialised in it */
    if (msg.in_size[1] != 0 || msg.in_size[2] != 0 || msg.in_size[3] != 0) {
        return PSA_ERROR_INVALID_ARGUMENT;
    }

    /* We expect exactly 2 output buffers, one for size, the other for data */
    if (msg.out_size[0] != sizeof(size_t) || msg.out_size[1] == 0 ||
        msg.out_size[2] != 0 || msg.out_size[3] != 0) {
        return PSA_ERROR_INVALID_ARGUMENT;
    }

    uint8_t *in_params = NULL;
    size_t in_params_len = 0;
    uint8_t *out_params = NULL;
    size_t out_params_len = 0;

    in_params_len = msg.in_size[0];
    in_params = malloc(in_params_len);
    if (in_params == NULL) {
        return PSA_ERROR_INSUFFICIENT_MEMORY;
    }

    /* Read the bytes from the client */
    size_t actual = psa_read(msg.handle, 0, in_params, in_params_len);
    if (actual != in_params_len) {
        free(in_params);
        return PSA_ERROR_CORRUPTION_DETECTED;
    }

    switch (func) {
EOF

    for my $function (@functions) {
        my $f = $functions{$function};
        my $enum = uc($function);

        # Create this call, in a way acceptable to uncustify:
        #            ok = ${function}_wrapper(in_params, in_params_len,
        #                                     &out_params, &out_params_len);
        my $first_line = "            ok = ${function}_wrapper(in_params, in_params_len,";
        my $idx = index($first_line, "(");
        die("can't find (") if $idx < 0;
        my $indent = " " x ($idx + 1);

        print $fh <<EOF;
        case $enum:
$first_line
$indent&out_params, &out_params_len);
            break;
EOF
    }

    print $fh <<EOF;
    }

    free(in_params);

    if (out_params_len > msg.out_size[1]) {
        fprintf(stderr, "unable to write %zu bytes into buffer of %zu bytes\\n",
                out_params_len, msg.out_size[1]);
        exit(1);
    }

    /* Write the exact amount of data we're returning */
    psa_write(msg.handle, 0, &out_params_len, sizeof(out_params_len));

    /* And write the data itself */
    if (out_params_len) {
        psa_write(msg.handle, 1, out_params, out_params_len);
    }

    free(out_params);

    return ok ? PSA_SUCCESS : PSA_ERROR_GENERIC_ERROR;
}
EOF

    # Finally, add psa_crypto_close()

    print $fh <<EOF;

void psa_crypto_close(void)
{
    psa_sim_serialize_reset();
}
EOF

    close($fh);
}

sub server_implementations_header
{
    return <<'EOF';
/* THIS FILE WAS AUTO-GENERATED BY psa_sim_generate.pl. DO NOT EDIT!! */

/* server implementations */

/*
 *  Copyright The Mbed TLS Contributors
 *  SPDX-License-Identifier: Apache-2.0 OR GPL-2.0-or-later
 */

#include <stdio.h>
#include <stdlib.h>

#include <psa/crypto.h>

#include "psa_functions_codes.h"
#include "psa_sim_serialise.h"

#include "service.h"

#if !defined(MBEDTLS_PSA_CRYPTO_C)
#error "Error: MBEDTLS_PSA_CRYPTO_C must be enabled on server build"
#endif
EOF
}

sub client_calls_header
{
    my $code = <<'EOF';
/* THIS FILE WAS AUTO-GENERATED BY psa_sim_generate.pl. DO NOT EDIT!! */

/* client calls */

/*
 *  Copyright The Mbed TLS Contributors
 *  SPDX-License-Identifier: Apache-2.0 OR GPL-2.0-or-later
 */

#include <stdio.h>
#include <unistd.h>

/* Includes from psasim */
#include <client.h>
#include <util.h>
#include "psa_manifest/sid.h"
#include "psa_functions_codes.h"
#include "psa_sim_serialise.h"

/* Includes from mbedtls */
#include "mbedtls/version.h"
#include "psa/crypto.h"

#define CLIENT_PRINT(fmt, ...) \
    INFO("Client: " fmt, ##__VA_ARGS__)

static psa_handle_t handle = -1;

#if defined(MBEDTLS_PSA_CRYPTO_C)
#error "Error: MBEDTLS_PSA_CRYPTO_C must be disabled on client build"
#endif
EOF

    $code .= debug_functions() if $debug;

    $code .= <<'EOF';

int psa_crypto_call(int function,
                    uint8_t *in_params, size_t in_params_len,
                    uint8_t **out_params, size_t *out_params_len)
{
    // psa_outvec outvecs[1];
    if (handle < 0) {
        fprintf(stderr, "NOT CONNECTED\n");
        exit(1);
    }

    psa_invec invec;
    invec.base = in_params;
    invec.len = in_params_len;

    size_t max_receive = 24576;
    uint8_t *receive = malloc(max_receive);
    if (receive == NULL) {
        fprintf(stderr, "FAILED to allocate %u bytes\n", (unsigned) max_receive);
        exit(1);
    }

    size_t actual_received = 0;

    psa_outvec outvecs[2];
    outvecs[0].base = &actual_received;
    outvecs[0].len = sizeof(actual_received);
    outvecs[1].base = receive;
    outvecs[1].len = max_receive;

    psa_status_t status = psa_call(handle, function, &invec, 1, outvecs, 2);
    if (status != PSA_SUCCESS) {
        free(receive);
        return 0;
    }

    *out_params = receive;
    *out_params_len = actual_received;

    return 1;   // success
}

psa_status_t psa_crypto_init(void)
{
    char mbedtls_version[18];
    uint8_t *result = NULL;
    size_t result_length;
    psa_status_t status = PSA_ERROR_CORRUPTION_DETECTED;

    mbedtls_version_get_string_full(mbedtls_version);
    CLIENT_PRINT("%s", mbedtls_version);

    CLIENT_PRINT("My PID: %d", getpid());

    CLIENT_PRINT("PSA version: %u", psa_version(PSA_SID_CRYPTO_SID));
    handle = psa_connect(PSA_SID_CRYPTO_SID, 1);

    if (handle < 0) {
        CLIENT_PRINT("Couldn't connect %d", handle);
        return PSA_ERROR_COMMUNICATION_FAILURE;
    }

    int ok = psa_crypto_call(PSA_CRYPTO_INIT, NULL, 0, &result, &result_length);
    CLIENT_PRINT("PSA_CRYPTO_INIT returned: %d", ok);

    if (!ok) {
        goto fail;
    }

    uint8_t *rpos = result;
    size_t rremain = result_length;

    ok = psasim_deserialise_begin(&rpos, &rremain);
    if (!ok) {
        goto fail;
    }

    ok = psasim_deserialise_psa_status_t(&rpos, &rremain, &status);
    if (!ok) {
        goto fail;
    }

fail:
    free(result);

    return status;
}

void mbedtls_psa_crypto_free(void)
{
    /* Do not try to close a connection that was never started.*/
    if (handle == -1) {
        return;
    }

    CLIENT_PRINT("Closing handle");
    psa_close(handle);
    handle = -1;
}
EOF
}

sub debug_functions
{
    return <<EOF;

static inline char hex_digit(char nibble) {
    return (nibble < 10) ? (nibble + '0') : (nibble + 'a' - 10);
}

int hex_byte(char *p, uint8_t b)
{
    p[0] = hex_digit(b >> 4);
    p[1] = hex_digit(b & 0x0F);

    return 2;
}

int hex_uint16(char *p, uint16_t b)
{
    hex_byte(p, b >> 8);
    hex_byte(p + 2, b & 0xFF);

    return 4;
}

char human_char(uint8_t c)
{
    return (c >= ' ' && c <= '~') ? (char)c : '.';
}

void dump_buffer(const uint8_t *buffer, size_t len)
{
    char line[80];

    const uint8_t *p = buffer;

    size_t max = (len > 0xFFFF) ? 0xFFFF : len;

    for (size_t i = 0; i < max; i += 16) {

        char *q = line;

        q += hex_uint16(q, (uint16_t)i);
        *q++ = ' ';
        *q++ = ' ';

        size_t ll = (i + 16 > max) ? (max % 16) : 16;

        size_t j;
        for (j = 0; j < ll; j++) {
            q += hex_byte(q, p[i + j]);
            *q++ = ' ';
        }

        while (j++ < 16) {
            *q++ = ' ';
            *q++ = ' ';
            *q++ = ' ';
        }

        *q++ = ' ';

        for (j = 0; j < ll; j++) {
            *q++ = human_char(p[i + j]);
        }

        *q = '\\0';

        printf("%s\\n", line);
    }
}

void hex_dump(uint8_t *p, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        printf("0x%02X ", p[i]);
    }
    printf("\\n");
}
EOF
}

sub output_server_wrapper
{
    my ($fh, $f, $name) = @_;

    my $ret_type = $f->{return}->{type};
    my $ret_name = $f->{return}->{name};
    my $ret_default = $f->{return}->{default};

    my @buffers = ();           # We need to free() these on exit

    print $fh <<EOF;

// Returns 1 for success, 0 for failure
int ${name}_wrapper(
    uint8_t *in_params, size_t in_params_len,
    uint8_t **out_params, size_t *out_params_len)
{
EOF

    print $fh <<EOF unless $ret_type eq "void";
    $ret_type $ret_name = $ret_default;
EOF
    # Output the variables we will need when we call the target function

    my $args = $f->{args};

    for my $i (0 .. $#$args) {
        my $arg = $args->[$i];
        my $argtype = $arg->{type};     # e.g. int, psa_algorithm_t, or "buffer"
        my $argname = $arg->{name};
        $argtype =~ s/^const //;

        if ($argtype =~ /^(const )?buffer$/) {
            my ($n1, $n2) = split(/,\s*/, $argname);
            print $fh <<EOF;
    uint8_t *$n1 = NULL;
    size_t $n2;
EOF
            push(@buffers, $n1);        # Add to the list to be free()d at end
        } else {
            $argname =~ s/^\*//;        # Remove any leading *
            my $pointer = ($argtype =~ /^psa_\w+_operation_t/) ? "*" : "";
            print $fh <<EOF;
    $argtype $pointer$argname;
EOF
        }
    }

    print $fh "\n";

    if ($#$args >= 0) {          # If we have any args (>= 0)
        print $fh <<EOF;
    uint8_t *pos = in_params;
    size_t remaining = in_params_len;
EOF
    }

    print $fh <<EOF;
    uint8_t *result = NULL;
    int ok;
EOF

    print $fh <<EOF if $debug;

    printf("$name: server\\n");
EOF
    if ($#$args >= 0) {          # If we have any args (>= 0)
        print $fh <<EOF;

    ok = psasim_deserialise_begin(&pos, &remaining);
    if (!ok) {
        goto fail;
    }
EOF
    }

    for my $i (0 .. $#$args) {
        my $arg = $args->[$i];
        my $argtype = $arg->{type};     # e.g. int, psa_algorithm_t, or "buffer"
        my $argname = $arg->{name};
        my $sep = ($i == $#$args) ? ";" : " +";
        $argtype =~ s/^const //;

        if ($argtype =~ /^(const )?buffer$/) {
            my ($n1, $n2) = split(/,\s*/, $argname);
            print $fh <<EOF;

    ok = psasim_deserialise_${argtype}(
        &pos, &remaining,
        &$n1, &$n2);
    if (!ok) {
        goto fail;
    }
EOF
        } else {
            $argname =~ s/^\*//;        # Remove any leading *
            my $server_specific = ($argtype =~ /^psa_\w+_operation_t/) ? "server_" : "";
            print $fh <<EOF;

    ok = psasim_${server_specific}deserialise_${argtype}(
        &pos, &remaining,
        &$argname);
    if (!ok) {
        goto fail;
    }
EOF
        }
    }

    print $fh <<EOF;

    // Now we call the actual target function
EOF
    output_call($fh, $f, $name, 1);

    my @outputs = grep($_->{is_output}, @$args);

    my $sep1 = (($ret_type eq "void") and ($#outputs < 0)) ? ";" : " +";

    print $fh <<EOF;

    // NOTE: Should really check there is no overflow as we go along.
    size_t result_size =
        psasim_serialise_begin_needs()$sep1
EOF

    if ($ret_type ne "void") {
        my $sep = ($#outputs < 0) ? ";" : " +";
        print $fh <<EOF;
        psasim_serialise_${ret_type}_needs($ret_name)$sep
EOF
    }

    for my $i (0 .. $#outputs) {
        my $arg = $outputs[$i];
        die("$i: this should have been filtered out by grep") unless $arg->{is_output};
        my $argtype = $arg->{type};     # e.g. int, psa_algorithm_t, or "buffer"
        my $argname = $arg->{name};
        my $sep = ($i == $#outputs) ? ";" : " +";
        $argtype =~ s/^const //;
        $argname =~ s/^\*//;        # Remove any leading *
        my $server_specific = ($argtype =~ /^psa_\w+_operation_t/) ? "server_" : "";

        print $fh <<EOF;
        psasim_${server_specific}serialise_${argtype}_needs($argname)$sep
EOF
    }

    print $fh <<EOF;

    result = malloc(result_size);
    if (result == NULL) {
        goto fail;
    }

    uint8_t *rpos = result;
    size_t rremain = result_size;

    ok = psasim_serialise_begin(&rpos, &rremain);
    if (!ok) {
        goto fail;
    }
EOF

    if ($ret_type ne "void") {
        print $fh <<EOF;

    ok = psasim_serialise_${ret_type}(
        &rpos, &rremain,
        $ret_name);
    if (!ok) {
        goto fail;
    }
EOF
    }

    my @outputs = grep($_->{is_output}, @$args);

    for my $i (0 .. $#outputs) {
        my $arg = $outputs[$i];
        die("$i: this should have been filtered out by grep") unless $arg->{is_output};
        my $argtype = $arg->{type};     # e.g. int, psa_algorithm_t, or "buffer"
        my $argname = $arg->{name};
        my $sep = ($i == $#outputs) ? ";" : " +";
        $argtype =~ s/^const //;

        if ($argtype eq "buffer") {
            print $fh <<EOF;

    ok = psasim_serialise_buffer(
        &rpos, &rremain,
        $argname);
    if (!ok) {
        goto fail;
    }
EOF
        } else {
            if ($argname =~ /^\*/) {
                $argname =~ s/^\*//;    # since it's already a pointer
            } else {
                die("$0: $argname: HOW TO OUTPUT?\n");
            }

            my $server_specific = ($argtype =~ /^psa_\w+_operation_t/) ? "server_" : "";

            my $completed = ""; # Only needed on server serialise calls
            if (length($server_specific)) {
                # On server serialisation, which is only for operation types,
                # we need to mark the operation as completed (variously called
                # terminated or inactive in psa/crypto.h) on certain calls.
                $completed = ($name =~ /_(abort|finish|hash_verify)$/) ? ", 1" : ", 0";
            }

            print $fh <<EOF;

    ok = psasim_${server_specific}serialise_${argtype}(
        &rpos, &rremain,
        $argname$completed);
    if (!ok) {
        goto fail;
    }
EOF
        }
    }

    my $free_buffers = join("", map { "    free($_);\n" } @buffers);
    $free_buffers = "\n" . $free_buffers if length($free_buffers);

    print $fh <<EOF;

    *out_params = result;
    *out_params_len = result_size;
$free_buffers
    return 1;   // success

fail:
    free(result);
$free_buffers
    return 0;       // This shouldn't happen!
}
EOF
}

sub output_client
{
    my ($fh, $f, $name) = @_;

    print $fh "\n";

    output_definition_begin($fh, $f, $name);

    my $ret_type = $f->{return}->{type};
    my $ret_name = $f->{return}->{name};
    my $ret_default = $f->{return}->{default};

    print $fh <<EOF;
{
    uint8_t *ser_params = NULL;
    uint8_t *ser_result = NULL;
    size_t result_length;
EOF
    print $fh <<EOF unless $ret_type eq "void";
    $ret_type $ret_name = $ret_default;
EOF

    print $fh <<EOF if $debug;

    printf("$name: client\\n");
EOF

    print $fh <<EOF;

    size_t needed =
        psasim_serialise_begin_needs() +
EOF

    my $args = $f->{args};

    for my $i (0 .. $#$args) {
        my $arg = $args->[$i];
        my $argtype = $arg->{type};     # e.g. int, psa_algorithm_t, or "buffer"
        my $argname = $arg->{name};
        my $sep = ($i == $#$args) ? ";" : " +";
        $argtype =~ s/^const //;

        print $fh <<EOF;
        psasim_serialise_${argtype}_needs($argname)$sep
EOF
    }

    print $fh <<EOF if $#$args < 0;
        0;
EOF

    print $fh <<EOF;

    ser_params = malloc(needed);
    if (ser_params == NULL) {
EOF

    if ($ret_type eq "psa_status_t") {
        print $fh <<EOF if $;
        $ret_name = PSA_ERROR_INSUFFICIENT_MEMORY;
EOF
    } elsif ($ret_type eq "uint32_t") {
        print $fh <<EOF if $;
        $ret_name = 0;
EOF
    }

    print $fh <<EOF;
        goto fail;
    }

    uint8_t *pos = ser_params;
    size_t remaining = needed;
    int ok;
    ok = psasim_serialise_begin(&pos, &remaining);
    if (!ok) {
        goto fail;
    }
EOF

    for my $i (0 .. $#$args) {
        my $arg = $args->[$i];
        my $argtype = $arg->{type};     # e.g. int, psa_algorithm_t, or "buffer"
        my $argname = $arg->{name};
        my $sep = ($i == $#$args) ? ";" : " +";
        $argtype =~ s/^const //;

        print $fh <<EOF;
    ok = psasim_serialise_${argtype}(
        &pos, &remaining,
        $argname);
    if (!ok) {
        goto fail;
    }
EOF
    }

    print $fh <<EOF if $debug;

    printf("client sending %d:\\n", (int)(pos - ser_params));
    dump_buffer(ser_params, (size_t)(pos - ser_params));
EOF

    my $enum = uc($name);

    print $fh <<EOF;

    ok = psa_crypto_call($enum,
                         ser_params, (size_t) (pos - ser_params), &ser_result, &result_length);
    if (!ok) {
        printf("$enum server call failed\\n");
        goto fail;
    }
EOF

    print $fh <<EOF if $debug;

    printf("client receiving %d:\\n", (int)result_length);
    dump_buffer(ser_result, result_length);
EOF

    print $fh <<EOF;

    uint8_t *rpos = ser_result;
    size_t rremain = result_length;

    ok = psasim_deserialise_begin(&rpos, &rremain);
    if (!ok) {
        goto fail;
    }
EOF

    print $fh <<EOF if $ret_type ne "void";

    ok = psasim_deserialise_$ret_type(
        &rpos, &rremain,
        &$ret_name);
    if (!ok) {
        goto fail;
    }
EOF

    my @outputs = grep($_->{is_output}, @$args);

    for my $i (0 .. $#outputs) {
        my $arg = $outputs[$i];
        die("$i: this should have been filtered out by grep") unless $arg->{is_output};
        my $argtype = $arg->{type};     # e.g. int, psa_algorithm_t, or "buffer"
        my $argname = $arg->{name};
        my $sep = ($i == $#outputs) ? ";" : " +";
        $argtype =~ s/^const //;

        if ($argtype eq "buffer") {
            print $fh <<EOF;

    ok = psasim_deserialise_return_buffer(
        &rpos, &rremain,
        $argname);
    if (!ok) {
        goto fail;
    }
EOF
        } else {
            if ($argname =~ /^\*/) {
                $argname =~ s/^\*//;    # since it's already a pointer
            } else {
                die("$0: $argname: HOW TO OUTPUT?\n");
            }

            print $fh <<EOF;

    ok = psasim_deserialise_${argtype}(
        &rpos, &rremain,
        $argname);
    if (!ok) {
        goto fail;
    }
EOF
        }
    }
    print $fh <<EOF;

fail:
    free(ser_params);
    free(ser_result);
EOF

    print $fh <<EOF if $ret_type ne "void";

    return $ret_name;
EOF

    print $fh <<EOF;
}
EOF
}

sub output_declaration
{
    my ($f, $name) = @_;

    output_signature($f, $name, "declaration");
}

sub output_definition_begin
{
    my ($fh, $f, $name) = @_;

    output_signature($fh, $f, $name, "definition");
}

sub output_call
{
    my ($fh, $f, $name, $is_server) = @_;

    my $ret_type = $f->{return}->{type};
    my $ret_name = $f->{return}->{name};
    my $args = $f->{args};

    if ($ret_type eq "void") {
        print $fh "\n    $name(\n";
    } else {
        print $fh "\n    $ret_name = $name(\n";
    }

    print $fh "        );\n" if $#$args < 0; # If no arguments, empty arg list

    for my $i (0 .. $#$args) {
        my $arg = $args->[$i];
        my $argtype = $arg->{type};     # e.g. int, psa_algorithm_t, or "buffer"
        my $argname = $arg->{name};

        if ($argtype =~ /^(const )?buffer$/) {
            my ($n1, $n2) = split(/,\s*/, $argname);
            print $fh "        $n1, $n2";
        } else {
            $argname =~ s/^\*/\&/;      # Replace leading * with &
            if ($is_server && $argtype =~ /^psa_\w+_operation_t/) {
                $argname =~ s/^\&//;    # Actually, for psa_XXX_operation_t, don't do this on the server side
            }
            print $fh "        $argname";
        }
        my $sep = ($i == $#$args) ? "\n        );" : ",";
        print $fh "$sep\n";
    }
}

sub output_signature
{
    my ($fh, $f, $name, $what) = @_;

    my $ret_type = $f->{return}->{type};
    my $args = $f->{args};

    my $final_sep = ($what eq "declaration") ? "\n);" : "\n    )";

    print $fh "\n$ret_type $name(\n";

    print $fh "    void\n    )\n" if $#$args < 0;   # No arguments

    for my $i (0 .. $#$args) {
        my $arg = $args->[$i];
        my $argtype = $arg->{type};             # e.g. int, psa_algorithm_t, or "buffer"
        my $ctypename = $arg->{ctypename};      # e.g. "int ", "char *"; empty for buffer
        my $argname = $arg->{name};

        if ($argtype =~ /^(const )?buffer$/) {
            my $const = length($1) ? "const " : "";
            my ($n1, $n2) = split(/,/, $argname);
            print $fh "    ${const}uint8_t *$n1, size_t $n2";
        } else {
            print $fh "    $ctypename$argname";
        }
        my $sep = ($i == $#$args) ? $final_sep : ",";
        print $fh "$sep\n";
    }
}

sub get_functions
{
    my $header_dir = 'tf-psa-crypto/include';
    my $src = "";
    for my $header_file ('psa/crypto.h', 'psa/crypto_extra.h') {
        local *HEADER;
        open HEADER, '<', "$header_dir/$header_file"
          or die "$header_dir/$header_file: $!";
        while (<HEADER>) {
            chomp;
            s/\/\/.*//;
            s/\s+^//;
            s/\s+/ /g;
            $_ .= "\n";
            $src .= $_;
        }
        close HEADER;
    }

    $src =~ s/\/\*.*?\*\///gs;

    my @src = split(/\n+/, $src);

    my @rebuild = ();
    my %funcs = ();
    for (my $i = 0; $i <= $#src; $i++) {
        my $line = $src[$i];
        if ($line =~ /^(static(?:\s+inline)?\s+)?
                       ((?:(?:enum|struct|union)\s+)?\w+\s*\**\s*)\s+
                       ((?:mbedtls|psa)_\w*)\(/x) {
            # begin function declaration
            #print "have one $line\n";
            while ($line !~ /;/) {
                $line .= $src[$i + 1];
                $i++;
            }
            if ($line =~ /^static/) {
                # IGNORE static inline functions: they're local.
                next;
            }
            $line =~ s/\s+/ /g;
            if ($line =~ /(\w+)\s+\b(\w+)\s*\(\s*(.*\S)\s*\)\s*[;{]/s) {
                my ($ret_type, $func, $args) = ($1, $2, $3);

                my $copy = $line;
                $copy =~ s/{$//;
                my $f = {
                    "orig" => $copy,
                };

                my @args = split(/\s*,\s*/, $args);

                my $ret_name = "";
                $ret_name = "status" if $ret_type eq "psa_status_t";
                $ret_name = "value" if $ret_type eq "uint32_t";
                $ret_name = "(void)" if $ret_type eq "void";
                die("ret_name for $ret_type?") unless length($ret_name);
                my $ret_default = "";
                $ret_default = "PSA_ERROR_CORRUPTION_DETECTED" if $ret_type eq "psa_status_t";
                $ret_default = "0" if $ret_type eq "uint32_t";
                $ret_default = "(void)" if $ret_type eq "void";
                die("ret_default for $ret_type?") unless length($ret_default);

                #print "FUNC $func RET_NAME $ret_name RET_TYPE $ret_type ARGS (", join("; ", @args), ")\n";

                $f->{return} = {
                    "type" => $ret_type,
                    "default" => $ret_default,
                    "name" => $ret_name,
                };
                $f->{args} = [];
                # psa_algorithm_t alg; const uint8_t *input; size_t input_length; uint8_t *hash; size_t hash_size; size_t *hash_length
                for (my $i = 0; $i <= $#args; $i++) {
                    my $arg = $args[$i];
                    # "type" => "psa_algorithm_t",
                    # "ctypename" => "psa_algorithm_t ",
                    # "name" => "alg",
                    # "is_output" => 0,
                    my ($type, $ctype, $name, $is_output);
                    if ($arg =~ /^(\w+)\s+(\w+)$/) {    # e.g. psa_algorithm_t alg
                        ($type, $name) = ($1, $2);
                        $ctype = $type . " ";
                        $is_output = 0;
                    } elsif ($arg =~ /^((const)\s+)?uint8_t\s*\*\s*(\w+)$/) {
                        $type = "buffer";
                        $is_output = (length($1) == 0) ? 1 : 0;
                        $type = "const buffer" if !$is_output;
                        $ctype = "";
                        $name = $3;
                        #print("$arg: $name: might be a buffer?\n");
                        die("$arg: not a buffer 1!\n") if $i == $#args;
                        my $next = $args[$i + 1];
                        if ($func eq "psa_key_derivation_verify_bytes" &&
                            $arg eq "const uint8_t *expected_output" &&
                            $next eq "size_t output_length") {
                            $next = "size_t expected_output_length";    # doesn't follow naming convention, so override
                        }
                        die("$arg: not a buffer 2!\n") if $next !~ /^size_t\s+(${name}_\w+)$/;
                        $i++;                   # We're using the next param here
                        my $nname = $1;
                        $name .= ", " . $nname;
                    } elsif ($arg =~ /^((const)\s+)?(\w+)\s*\*(\w+)$/) {
                        ($type, $name) = ($3, "*" . $4);
                        $ctype = $1 . $type . " ";
                        $is_output = (length($1) == 0) ? 1 : 0;
                    } elsif ($arg eq "void") {
                         # we'll just ignore this one
                    } else {
                        die("ARG HELP $arg\n");
                    }
                    #print "$arg => <$type><$ctype><$name><$is_output>\n";
                    if ($arg ne "void") {
                        push(@{$f->{args}}, {
                            "type" => $type,
                            "ctypename" => $ctype,
                            "name" => $name,
                            "is_output" => $is_output,
                        });
                    }
                }
                $funcs{$func} = $f;
            } else {
                die("FAILED");
            }
            push(@rebuild, $line);
        } elsif ($line =~ /^#/i) {
            # IGNORE directive
            while ($line =~ /\\$/) {
                $i++;
                $line = $src[$i];
            }
        } elsif ($line =~ /^(?:typedef +)?(enum|struct|union)[^;]*$/) {
            # IGNORE compound type definition
            while ($line !~ /^\}/) {
                $i++;
                $line = $src[$i];
            }
        } elsif ($line =~ /^typedef /i) {
            # IGNORE type definition
        } elsif ($line =~ / = .*;$/) {
            # IGNORE assignment in inline function definition
        } else {
            if ($line =~ /psa_/) {
                print "NOT PARSED: $line\n";
            }
            push(@rebuild, $line);
        }
    }

    #print ::Dumper(\%funcs);
    #exit;

    return %funcs;
}
