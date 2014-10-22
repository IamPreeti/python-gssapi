GSSAPI="BASE"  # This ensures that a full module is generated by Cython

from libc.string cimport memcmp, memcpy, memset
from libc.stdlib cimport free, malloc, calloc

from gssapi.raw.cython_types cimport *
from gssapi.raw.names cimport Name
from gssapi.raw.creds cimport Creds
from gssapi.raw.oids cimport OID
from gssapi.raw.cython_converters cimport c_create_mech_list
from gssapi.raw.cython_converters cimport c_get_mech_oid_set
from gssapi.raw.cython_converters cimport c_c_ttl_to_py, c_py_ttl_to_c

from collections import namedtuple

from gssapi.raw.named_tuples import AddCredResult, AcquireCredResult
from gssapi.raw.named_tuples import StoreCredResult
from gssapi.raw.misc import GSSError


cdef extern from "gssapi/gssapi_ext.h":
    ctypedef struct gss_key_value_element_desc:
        const char *key
        const char *value

    ctypedef struct gss_key_value_set_desc:
        OM_uint32 count
        gss_key_value_element_desc *elements

    OM_uint32 gss_acquire_cred_from(OM_uint32 *min_stat,
                                    gss_name_t desired_name,
                                    OM_uint32 ttl,
                                    gss_OID_set desired_mechs,
                                    gss_cred_usage_t cred_usage,
                                    const gss_key_value_set_desc *cred_store,
                                    gss_cred_id_t *output_creds,
                                    gss_OID_set *actual_mechs,
                                    OM_uint32 *actual_ttl) nogil

    OM_uint32 gss_add_cred_from(OM_uint32 *min_stat,
                                gss_cred_id_t input_creds,
                                gss_name_t desired_name,
                                gss_OID desired_mech,
                                gss_cred_usage_t cred_usage,
                                OM_uint32 initiator_ttl,
                                OM_uint32 acceptor_ttl,
                                const gss_key_value_set_desc *cred_store,
                                gss_cred_id_t *output_creds,
                                gss_OID_set *actual_mechs,
                                OM_uint32 *actual_initiator_ttl,
                                OM_uint32 *actual_acceptor_ttl) nogil

    OM_uint32 gss_store_cred_into(OM_uint32 *min_stat,
                                  gss_cred_id_t input_creds,
                                  gss_cred_usage_t cred_usage,
                                  gss_OID desired_mech,
                                  OM_uint32 overwrite_cred,
                                  OM_uint32 default_cred,
                                  const gss_key_value_set_desc *cred_store,
                                  gss_OID_set *elements_stored,
                                  gss_cred_usage_t *actual_usage) nogil

    # null value for cred stores
    gss_key_value_set_desc *GSS_C_NO_CRED_STORE


cdef gss_key_value_set_desc* c_create_key_value_set(dict values) except NULL:
    cdef gss_key_value_set_desc* res = <gss_key_value_set_desc*>malloc(
        sizeof(gss_key_value_set_desc))
    if res is NULL:
        raise MemoryError("Could not allocate memory for "
                          "key-value set")

    res.count = len(values)

    res.elements = <gss_key_value_element_desc*>calloc(
        res.count, sizeof(gss_key_value_element_desc))

    if res.elements is NULL:
        raise MemoryError("Could not allocate memory for "
                          "key-value set elements")

    for (i, (k, v)) in enumerate(values.items()):
        res.elements[i].key = k
        res.elements[i].value = v

    return res


cdef void c_free_key_value_set(gss_key_value_set_desc *kvset):
    free(kvset.elements)
    free(kvset)


# TODO(directxman12): some of these probably need a "not null",
#                     but that's not clear from the wiki page
def acquire_cred_from(dict store, Name name, ttl=None,
                      mechs=None, cred_usage='both'):

    cdef gss_OID_set desired_mechs
    if mechs is not None:
        desired_mechs = c_get_mech_oid_set(mechs)
    else:
        desired_mechs = GSS_C_NO_OID_SET

    cdef OM_uint32 input_ttl = c_py_ttl_to_c(ttl)

    cdef gss_name_t c_name
    if name is None:
        c_name = GSS_C_NO_NAME
    else:
        c_name = name.raw_name

    cdef gss_cred_usage_t usage
    if cred_usage == 'initiate':
        usage = GSS_C_INITIATE
    elif cred_usage == 'accept':
        usage = GSS_C_ACCEPT
    else:
        usage = GSS_C_BOTH

    cdef gss_key_value_set_desc *c_store
    if store is not None:
        c_store = c_create_key_value_set(store)
    else:
        c_store = GSS_C_NO_CRED_STORE

    cdef gss_cred_id_t creds
    cdef gss_OID_set actual_mechs
    cdef OM_uint32 actual_ttl

    cdef OM_uint32 maj_stat, min_stat

    with nogil:
        maj_stat = gss_acquire_cred_from(&min_stat, c_name, input_ttl,
                                         desired_mechs, usage, c_store,
                                         &creds, &actual_mechs, &actual_ttl)

    cdef OM_uint32 tmp_min_stat
    if mechs is not None:
        gss_release_oid_set(&tmp_min_stat, &desired_mechs)

    if store is not None:
        c_free_key_value_set(c_store)

    cdef Creds rc = Creds()
    if maj_stat == GSS_S_COMPLETE:
        rc.raw_creds = creds
        return AcquireCredResult(rc, c_create_mech_list(actual_mechs),
                                 c_c_ttl_to_py(actual_ttl))
    else:
        raise GSSError(maj_stat, min_stat)


def add_cred_from(dict store, Creds input_creds,
                  Name name not None, OID mech not None,
                  cred_usage='both', initiator_ttl=None,
                  acceptor_ttl=None):

    cdef OM_uint32 input_initiator_ttl = c_py_ttl_to_c(initiator_ttl)
    cdef OM_uint32 input_acceptor_ttl = c_py_ttl_to_c(acceptor_ttl)

    cdef gss_cred_usage_t usage
    if cred_usage == 'initiate':
        usage = GSS_C_INITIATE
    elif cred_usage == 'accept':
        usage = GSS_C_ACCEPT
    else:
        usage = GSS_C_BOTH

    cdef gss_name_t c_name = name.raw_name
    cdef gss_OID c_mech = &mech.raw_oid

    cdef gss_cred_id_t c_input_creds
    if input_creds is not None:
        c_input_creds = input_creds.raw_creds
    else:
        c_input_creds = GSS_C_NO_CREDENTIAL

    cdef gss_key_value_set_desc *c_store
    if store is not None:
        c_store = c_create_key_value_set(store)
    else:
        c_store = GSS_C_NO_CRED_STORE

    cdef gss_cred_id_t creds
    cdef gss_OID_set actual_mechs
    cdef OM_uint32 actual_initiator_ttl
    cdef OM_uint32 actual_acceptor_ttl

    cdef OM_uint32 maj_stat, min_stat

    with nogil:
        maj_stat = gss_add_cred_from(&min_stat, c_input_creds, c_name,
                                     c_mech, usage, input_initiator_ttl,
                                     input_acceptor_ttl, c_store, &creds,
                                     &actual_mechs, &actual_initiator_ttl,
                                     &actual_acceptor_ttl)

    if store is not None:
        c_free_key_value_set(c_store)

    cdef Creds rc
    if maj_stat == GSS_S_COMPLETE:
        rc = Creds()
        rc.raw_creds = creds
        return AddCredResult(rc, c_create_mech_list(actual_mechs),
                             c_c_ttl_to_py(actual_initiator_ttl),
                             c_c_ttl_to_py(actual_acceptor_ttl))
    else:
        raise GSSError(maj_stat, min_stat)


def store_cred_into(dict store, Creds creds not None,
                    cred_usage='both', OID mech=None, bint overwrite=False,
                    bint set_default=False):
    cdef gss_OID desired_mech
    if mech is not None:
        desired_mech = &mech.raw_oid
    else:
        desired_mech = GSS_C_NO_OID

    cdef gss_cred_usage_t usage
    if cred_usage == 'initiate':
        usage = GSS_C_INITIATE
    elif cred_usage == 'accept':
        usage = GSS_C_ACCEPT
    else:
        usage = GSS_C_BOTH

    cdef gss_key_value_set_desc *c_store
    if store is not None:
        c_store = c_create_key_value_set(store)
    else:
        c_store = GSS_C_NO_CRED_STORE

    cdef gss_cred_id_t c_creds = creds.raw_creds

    cdef gss_OID_set actual_mech_types
    cdef gss_cred_usage_t actual_usage

    cdef OM_uint32 maj_stat, min_stat

    with nogil:
        maj_stat = gss_store_cred_into(&min_stat, c_creds, usage,
                                       desired_mech, overwrite,
                                       set_default, c_store,
                                       &actual_mech_types,
                                       &actual_usage)

    if store is not None:
        c_free_key_value_set(c_store)

    if maj_stat == GSS_S_COMPLETE:
        if actual_usage == GSS_C_INITIATE:
            py_actual_usage = 'initiate'
        elif actual_usage == GSS_C_ACCEPT:
            py_actual_usage = 'accept'
        else:
            py_actual_usage = 'both'

        return StoreCredResult(c_create_mech_list(actual_mech_types),
                               py_actual_usage)
    else:
        raise GSSError(maj_stat, min_stat)