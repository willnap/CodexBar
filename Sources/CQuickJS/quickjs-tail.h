/*
 * QuickJS Javascript Engine
 *
 * Copyright (c) 2017-2026 Fabrice Bellard
 * Copyright (c) 2017-2025 Charlie Gordon
 * Copyright (c) 2023-2026 Ben Noordhuis
 * Copyright (c) 2023-2026 Saúl Ibarra Corretgé
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

#line 51904 "quickjs.c"
static JSValue js_reflect_apply(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv)
{
    return js_function_apply(ctx, argv[0], max_int(0, argc - 1), argv + 1, 2);
}

static JSValue js_reflect_construct(JSContext *ctx, JSValueConst this_val,
                                    int argc, JSValueConst *argv)
{
    JSValueConst func, array_arg, new_target;
    JSValue *tab, ret;
    uint32_t len;

    func = argv[0];
    array_arg = argv[1];
    if (argc > 2) {
        new_target = argv[2];
        if (!JS_IsConstructor(ctx, new_target))
            return JS_ThrowTypeErrorNotAConstructor(ctx, new_target);
    } else {
        new_target = func;
    }
    tab = build_arg_list(ctx, &len, array_arg);
    if (!tab)
        return JS_EXCEPTION;
    ret = JS_CallConstructor2(ctx, func, new_target, len, vc(tab));
    free_arg_list(ctx, tab, len);
    return ret;
}

static JSValue js_reflect_deleteProperty(JSContext *ctx, JSValueConst this_val,
                                         int argc, JSValueConst *argv)
{
    JSValueConst obj;
    JSAtom atom;
    int ret;

    obj = argv[0];
    if (JS_VALUE_GET_TAG(obj) != JS_TAG_OBJECT)
        return JS_ThrowTypeErrorNotAnObject(ctx);
    atom = JS_ValueToAtom(ctx, argv[1]);
    if (unlikely(atom == JS_ATOM_NULL))
        return JS_EXCEPTION;
    ret = JS_DeleteProperty(ctx, obj, atom, 0);
    JS_FreeAtom(ctx, atom);
    if (ret < 0)
        return JS_EXCEPTION;
    else
        return js_bool(ret);
}

static JSValue js_reflect_get(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv)
{
    JSValueConst obj, prop, receiver;
    JSAtom atom;
    JSValue ret;

    obj = argv[0];
    prop = argv[1];
    if (JS_VALUE_GET_TAG(obj) != JS_TAG_OBJECT)
        return JS_ThrowTypeErrorNotAnObject(ctx);
    if (argc > 2)
        receiver = argv[2];
    else
        receiver = obj;
    atom = JS_ValueToAtom(ctx, prop);
    if (unlikely(atom == JS_ATOM_NULL))
        return JS_EXCEPTION;
    ret = JS_GetPropertyInternal(ctx, obj, atom, receiver, false);
    JS_FreeAtom(ctx, atom);
    return ret;
}

static JSValue js_reflect_has(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv)
{
    JSValueConst obj, prop;
    JSAtom atom;
    int ret;

    obj = argv[0];
    prop = argv[1];
    if (JS_VALUE_GET_TAG(obj) != JS_TAG_OBJECT)
        return JS_ThrowTypeErrorNotAnObject(ctx);
    atom = JS_ValueToAtom(ctx, prop);
    if (unlikely(atom == JS_ATOM_NULL))
        return JS_EXCEPTION;
    ret = JS_HasProperty(ctx, obj, atom);
    JS_FreeAtom(ctx, atom);
    if (ret < 0)
        return JS_EXCEPTION;
    else
        return js_bool(ret);
}

static JSValue js_reflect_set(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv)
{
    JSValueConst obj, prop, val, receiver;
    int ret;
    JSAtom atom;

    obj = argv[0];
    prop = argv[1];
    val = argv[2];
    if (argc > 3)
        receiver = argv[3];
    else
        receiver = obj;
    if (JS_VALUE_GET_TAG(obj) != JS_TAG_OBJECT)
        return JS_ThrowTypeErrorNotAnObject(ctx);
    atom = JS_ValueToAtom(ctx, prop);
    if (unlikely(atom == JS_ATOM_NULL))
        return JS_EXCEPTION;
    ret = JS_SetPropertyInternal2(ctx, obj, atom, js_dup(val), receiver, 0);
    JS_FreeAtom(ctx, atom);
    if (ret < 0)
        return JS_EXCEPTION;
    else
        return js_bool(ret);
}

static JSValue js_reflect_setPrototypeOf(JSContext *ctx, JSValueConst this_val,
                                         int argc, JSValueConst *argv)
{
    int ret;
    ret = JS_SetPrototypeInternal(ctx, argv[0], argv[1], false);
    if (ret < 0)
        return JS_EXCEPTION;
    else
        return js_bool(ret);
}

static JSValue js_reflect_ownKeys(JSContext *ctx, JSValueConst this_val,
                                  int argc, JSValueConst *argv)
{
    if (JS_VALUE_GET_TAG(argv[0]) != JS_TAG_OBJECT)
        return JS_ThrowTypeErrorNotAnObject(ctx);
    return JS_GetOwnPropertyNames2(ctx, argv[0],
                                   JS_GPN_STRING_MASK | JS_GPN_SYMBOL_MASK,
                                   JS_ITERATOR_KIND_KEY);
}

static const JSCFunctionListEntry js_reflect_funcs[] = {
    JS_CFUNC_DEF("apply", 3, js_reflect_apply ),
    JS_CFUNC_DEF("construct", 2, js_reflect_construct ),
    JS_CFUNC_MAGIC_DEF("defineProperty", 3, js_object_defineProperty, 1 ),
    JS_CFUNC_DEF("deleteProperty", 2, js_reflect_deleteProperty ),
    JS_CFUNC_DEF("get", 2, js_reflect_get ),
    JS_CFUNC_MAGIC_DEF("getOwnPropertyDescriptor", 2, js_object_getOwnPropertyDescriptor, 1 ),
    JS_CFUNC_MAGIC_DEF("getPrototypeOf", 1, js_object_getPrototypeOf, 1 ),
    JS_CFUNC_DEF("has", 2, js_reflect_has ),
    JS_CFUNC_MAGIC_DEF("isExtensible", 1, js_object_isExtensible, 1 ),
    JS_CFUNC_DEF("ownKeys", 1, js_reflect_ownKeys ),
    JS_CFUNC_MAGIC_DEF("preventExtensions", 1, js_object_preventExtensions, 1 ),
    JS_CFUNC_DEF("set", 3, js_reflect_set ),
    JS_CFUNC_DEF("setPrototypeOf", 2, js_reflect_setPrototypeOf ),
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "Reflect", JS_PROP_CONFIGURABLE ),
};

static const JSCFunctionListEntry js_reflect_obj[] = {
    JS_OBJECT_DEF("Reflect", js_reflect_funcs, countof(js_reflect_funcs), JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE ),
};

/* Proxy */

static void js_proxy_finalizer(JSRuntime *rt, JSValueConst val)
{
    JSProxyData *s = JS_GetOpaque(val, JS_CLASS_PROXY);
    if (s) {
        JS_FreeValueRT(rt, s->target);
        JS_FreeValueRT(rt, s->handler);
        js_free_rt(rt, s);
    }
}

static void js_proxy_mark(JSRuntime *rt, JSValueConst val,
                          JS_MarkFunc *mark_func)
{
    JSProxyData *s = JS_GetOpaque(val, JS_CLASS_PROXY);
    if (s) {
        JS_MarkValue(rt, s->target, mark_func);
        JS_MarkValue(rt, s->handler, mark_func);
    }
}

static JSValue JS_ThrowTypeErrorRevokedProxy(JSContext *ctx)
{
    return JS_ThrowTypeError(ctx, "revoked proxy");
}

static JSProxyData *get_proxy_method(JSContext *ctx, JSValue *pmethod,
                                     JSValueConst obj, JSAtom name)
{
    JSProxyData *s = JS_GetOpaque(obj, JS_CLASS_PROXY);
    JSValue method;

    /* safer to test recursion in all proxy methods */
    if (js_check_stack_overflow(ctx->rt, 0)) {
        JS_ThrowStackOverflow(ctx);
        return NULL;
    }

    /* 's' should never be NULL */
    if (s->is_revoked) {
        JS_ThrowTypeErrorRevokedProxy(ctx);
        return NULL;
    }
    method = JS_GetProperty(ctx, s->handler, name);
    if (JS_IsException(method))
        return NULL;
    if (JS_IsNull(method))
        method = JS_UNDEFINED;
    *pmethod = method;
    return s;
}

static JSValue js_proxy_getPrototypeOf(JSContext *ctx, JSValueConst obj)
{
    JSProxyData *s;
    JSValue method, ret, proto1;
    int res;

    s = get_proxy_method(ctx, &method, obj, JS_ATOM_getPrototypeOf);
    if (!s)
        return JS_EXCEPTION;
    if (JS_IsUndefined(method))
        return JS_GetPrototype(ctx, s->target);
    ret = JS_CallFree(ctx, method, s->handler, 1, vc(&s->target));
    if (JS_IsException(ret))
        return ret;
    if (JS_VALUE_GET_TAG(ret) != JS_TAG_NULL &&
        JS_VALUE_GET_TAG(ret) != JS_TAG_OBJECT) {
        goto fail;
    }
    res = JS_IsExtensible(ctx, s->target);
    if (res < 0) {
        JS_FreeValue(ctx, ret);
        return JS_EXCEPTION;
    }
    if (!res) {
        /* check invariant */
        proto1 = JS_GetPrototype(ctx, s->target);
        if (JS_IsException(proto1)) {
            JS_FreeValue(ctx, ret);
            return JS_EXCEPTION;
        }
        if (JS_VALUE_GET_OBJ(proto1) != JS_VALUE_GET_OBJ(ret)) {
            JS_FreeValue(ctx, proto1);
        fail:
            JS_FreeValue(ctx, ret);
            return JS_ThrowTypeError(ctx, "proxy: inconsistent prototype");
        }
        JS_FreeValue(ctx, proto1);
    }
    return ret;
}

static int js_proxy_setPrototypeOf(JSContext *ctx, JSValueConst obj,
                                   JSValueConst proto_val, bool throw_flag)
{
    JSProxyData *s;
    JSValue method, ret, proto1;
    JSValueConst args[2];
    bool res;
    int res2;

    s = get_proxy_method(ctx, &method, obj, JS_ATOM_setPrototypeOf);
    if (!s)
        return -1;
    if (JS_IsUndefined(method))
        return JS_SetPrototypeInternal(ctx, s->target, proto_val, throw_flag);
    args[0] = s->target;
    args[1] = proto_val;
    ret = JS_CallFree(ctx, method, s->handler, 2, args);
    if (JS_IsException(ret))
        return -1;
    res = JS_ToBoolFree(ctx, ret);
    if (!res) {
        if (throw_flag) {
            JS_ThrowTypeError(ctx, "proxy: bad prototype");
            return -1;
        } else {
            return false;
        }
    }
    res2 = JS_IsExtensible(ctx, s->target);
    if (res2 < 0)
        return -1;
    if (!res2) {
        proto1 = JS_GetPrototype(ctx, s->target);
        if (JS_IsException(proto1))
            return -1;
        if (JS_VALUE_GET_OBJ(proto_val) != JS_VALUE_GET_OBJ(proto1)) {
            JS_FreeValue(ctx, proto1);
            JS_ThrowTypeError(ctx, "proxy: inconsistent prototype");
            return -1;
        }
        JS_FreeValue(ctx, proto1);
    }
    return true;
}

static int js_proxy_isExtensible(JSContext *ctx, JSValueConst obj)
{
    JSProxyData *s;
    JSValue method, ret;
    bool res;
    int res2;

    s = get_proxy_method(ctx, &method, obj, JS_ATOM_isExtensible);
    if (!s)
        return -1;
    if (JS_IsUndefined(method))
        return JS_IsExtensible(ctx, s->target);
    ret = JS_CallFree(ctx, method, s->handler, 1, vc(&s->target));
    if (JS_IsException(ret))
        return -1;
    res = JS_ToBoolFree(ctx, ret);
    res2 = JS_IsExtensible(ctx, s->target);
    if (res2 < 0)
        return res2;
    if (res != res2) {
        JS_ThrowTypeError(ctx, "proxy: inconsistent isExtensible");
        return -1;
    }
    return res;
}

static int js_proxy_preventExtensions(JSContext *ctx, JSValueConst obj)
{
    JSProxyData *s;
    JSValue method, ret;
    bool res;
    int res2;

    s = get_proxy_method(ctx, &method, obj, JS_ATOM_preventExtensions);
    if (!s)
        return -1;
    if (JS_IsUndefined(method))
        return JS_PreventExtensions(ctx, s->target);
    ret = JS_CallFree(ctx, method, s->handler, 1, vc(&s->target));
    if (JS_IsException(ret))
        return -1;
    res = JS_ToBoolFree(ctx, ret);
    if (res) {
        res2 = JS_IsExtensible(ctx, s->target);
        if (res2 < 0)
            return res2;
        if (res2) {
            JS_ThrowTypeError(ctx, "proxy: inconsistent preventExtensions");
            return -1;
        }
    }
    return res;
}

static int js_proxy_has(JSContext *ctx, JSValueConst obj, JSAtom atom)
{
    JSProxyData *s;
    JSValue method, ret1, atom_val;
    int res;
    JSObject *p;
    JSValueConst args[2];
    bool ret;

    s = get_proxy_method(ctx, &method, obj, JS_ATOM_has);
    if (!s)
        return -1;
    if (JS_IsUndefined(method))
        return JS_HasProperty(ctx, s->target, atom);
    atom_val = JS_AtomToValue(ctx, atom);
    if (JS_IsException(atom_val)) {
        JS_FreeValue(ctx, method);
        return -1;
    }
    args[0] = s->target;
    args[1] = atom_val;
    ret1 = JS_CallFree(ctx, method, s->handler, 2, args);
    JS_FreeValue(ctx, atom_val);
    if (JS_IsException(ret1))
        return -1;
    ret = JS_ToBoolFree(ctx, ret1);
    if (!ret) {
        int desc_flags;
        p = JS_VALUE_GET_OBJ(s->target);
        res = JS_GetOwnPropertyFlagsInternal(ctx, &desc_flags, p, atom);
        if (res < 0)
            return -1;
        if (res) {
            if (!(desc_flags & JS_PROP_CONFIGURABLE))
                goto inconsistent;
            /* must go through IsExtensible(): the target can be a proxy
               itself, whose isExtensible trap is observable */
            res = JS_IsExtensible(ctx, s->target);
            if (res < 0)
                return -1;
            if (!res) {
            inconsistent:
                JS_ThrowTypeError(ctx, "proxy: inconsistent has");
                return -1;
            }
        }
    }
    return ret;
}

static JSValue js_proxy_get(JSContext *ctx, JSValueConst obj, JSAtom atom,
                            JSValueConst receiver)
{
    JSProxyData *s;
    JSValue method, ret, atom_val;
    int res;
    JSValueConst args[3];
    JSPropertyDescriptor desc;

    s = get_proxy_method(ctx, &method, obj, JS_ATOM_get);
    if (!s)
        return JS_EXCEPTION;
    /* Note: recursion is possible thru the prototype of s->target */
    if (JS_IsUndefined(method))
        return JS_GetPropertyInternal(ctx, s->target, atom, receiver, false);
    atom_val = JS_AtomToValue(ctx, atom);
    if (JS_IsException(atom_val)) {
        JS_FreeValue(ctx, method);
        return JS_EXCEPTION;
    }
    args[0] = s->target;
    args[1] = atom_val;
    args[2] = receiver;
    ret = JS_CallFree(ctx, method, s->handler, 3, args);
    JS_FreeValue(ctx, atom_val);
    if (JS_IsException(ret))
        return JS_EXCEPTION;
    res = JS_GetOwnPropertyInternal(ctx, &desc, JS_VALUE_GET_OBJ(s->target), atom);
    if (res < 0) {
        JS_FreeValue(ctx, ret);
        return JS_EXCEPTION;
    }
    if (res) {
        if ((desc.flags & (JS_PROP_GETSET | JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE)) == 0) {
            if (!js_same_value(ctx, desc.value, ret)) {
                goto fail;
            }
        } else if ((desc.flags & (JS_PROP_GETSET | JS_PROP_CONFIGURABLE)) == JS_PROP_GETSET) {
            if (JS_IsUndefined(desc.getter) && !JS_IsUndefined(ret)) {
            fail:
                js_free_desc(ctx, &desc);
                JS_FreeValue(ctx, ret);
                return JS_ThrowTypeError(ctx, "proxy: inconsistent get");
            }
        }
        js_free_desc(ctx, &desc);
    }
    return ret;
}

static int js_proxy_set(JSContext *ctx, JSValueConst obj, JSAtom atom,
                        JSValueConst value, JSValueConst receiver, int flags)
{
    JSProxyData *s;
    JSValue method, ret1, atom_val;
    bool ret;
    int res;
    JSValueConst args[4];

    s = get_proxy_method(ctx, &method, obj, JS_ATOM_set);
    if (!s)
        return -1;
    if (JS_IsUndefined(method)) {
        return JS_SetPropertyInternal2(ctx, s->target, atom,
                                       js_dup(value), receiver, flags);
    }
    atom_val = JS_AtomToValue(ctx, atom);
    if (JS_IsException(atom_val)) {
        JS_FreeValue(ctx, method);
        return -1;
    }
    args[0] = s->target;
    args[1] = atom_val;
    args[2] = value;
    args[3] = receiver;
    ret1 = JS_CallFree(ctx, method, s->handler, 4, args);
    JS_FreeValue(ctx, atom_val);
    if (JS_IsException(ret1))
        return -1;
    ret = JS_ToBoolFree(ctx, ret1);
    if (ret) {
        JSPropertyDescriptor desc;
        res = JS_GetOwnPropertyInternal(ctx, &desc, JS_VALUE_GET_OBJ(s->target), atom);
        if (res < 0)
            return -1;
        if (res) {
            if ((desc.flags & (JS_PROP_GETSET | JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE)) == 0) {
                if (!js_same_value(ctx, desc.value, value)) {
                    goto fail;
                }
            } else if ((desc.flags & (JS_PROP_GETSET | JS_PROP_CONFIGURABLE)) == JS_PROP_GETSET && JS_IsUndefined(desc.setter)) {
                fail:
                    js_free_desc(ctx, &desc);
                    JS_ThrowTypeError(ctx, "proxy: inconsistent set");
                    return -1;
            }
            js_free_desc(ctx, &desc);
        }
    } else {
        if ((flags & JS_PROP_THROW) ||
            ((flags & JS_PROP_THROW_STRICT) && is_strict_mode(ctx))) {
            JS_ThrowTypeError(ctx, "proxy: cannot set property");
            return -1;
        }
    }
    return ret;
}

static JSValue js_create_desc(JSContext *ctx, JSValueConst val,
                              JSValueConst getter, JSValueConst setter,
                              int flags)
{
    JSValue ret;
    ret = JS_NewObject(ctx);
    if (JS_IsException(ret))
        return ret;
    if (flags & JS_PROP_HAS_GET) {
        JS_DefinePropertyValueConst(ctx, ret, JS_ATOM_get, getter,
                                    JS_PROP_C_W_E);
    }
    if (flags & JS_PROP_HAS_SET) {
        JS_DefinePropertyValueConst(ctx, ret, JS_ATOM_set, setter,
                                    JS_PROP_C_W_E);
    }
    if (flags & JS_PROP_HAS_VALUE) {
        JS_DefinePropertyValueConst(ctx, ret, JS_ATOM_value, val,
                                    JS_PROP_C_W_E);
    }
    if (flags & JS_PROP_HAS_WRITABLE) {
        JS_DefinePropertyValue(ctx, ret, JS_ATOM_writable,
                               js_bool(flags & JS_PROP_WRITABLE),
                               JS_PROP_C_W_E);
    }
    if (flags & JS_PROP_HAS_ENUMERABLE) {
        JS_DefinePropertyValue(ctx, ret, JS_ATOM_enumerable,
                               js_bool(flags & JS_PROP_ENUMERABLE),
                               JS_PROP_C_W_E);
    }
    if (flags & JS_PROP_HAS_CONFIGURABLE) {
        JS_DefinePropertyValue(ctx, ret, JS_ATOM_configurable,
                               js_bool(flags & JS_PROP_CONFIGURABLE),
                               JS_PROP_C_W_E);
    }
    return ret;
}

static int js_proxy_get_own_property(JSContext *ctx, JSPropertyDescriptor *pdesc,
                                     JSValueConst obj, JSAtom prop)
{
    JSProxyData *s;
    JSValue method, trap_result_obj, prop_val;
    int res, target_desc_ret, ret;
    JSObject *p;
    JSValueConst args[2];
    JSPropertyDescriptor result_desc, target_desc;

    s = get_proxy_method(ctx, &method, obj, JS_ATOM_getOwnPropertyDescriptor);
    if (!s)
        return -1;
    p = JS_VALUE_GET_OBJ(s->target);
    if (JS_IsUndefined(method)) {
        return JS_GetOwnPropertyInternal(ctx, pdesc, p, prop);
    }
    prop_val = JS_AtomToValue(ctx, prop);
    if (JS_IsException(prop_val)) {
        JS_FreeValue(ctx, method);
        return -1;
    }
    args[0] = s->target;
    args[1] = prop_val;
    trap_result_obj = JS_CallFree(ctx, method, s->handler, 2, args);
    JS_FreeValue(ctx, prop_val);
    if (JS_IsException(trap_result_obj))
        return -1;
    if (!JS_IsObject(trap_result_obj) && !JS_IsUndefined(trap_result_obj)) {
        JS_FreeValue(ctx, trap_result_obj);
        goto fail;
    }
    target_desc_ret = JS_GetOwnPropertyInternal(ctx, &target_desc, p, prop);
    if (target_desc_ret < 0) {
        JS_FreeValue(ctx, trap_result_obj);
        return -1;
    }
    if (target_desc_ret)
        js_free_desc(ctx, &target_desc);
    if (JS_IsUndefined(trap_result_obj)) {
        if (target_desc_ret) {
            if (!(target_desc.flags & JS_PROP_CONFIGURABLE))
                goto fail;
            /* must go through IsExtensible(): the target can be a proxy
               itself, whose isExtensible trap is observable */
            res = JS_IsExtensible(ctx, s->target);
            if (res < 0)
                return -1;
            if (!res)
                goto fail;
        }
        ret = false;
    } else {
        int flags1, extensible_target;
        extensible_target = JS_IsExtensible(ctx, s->target);
        if (extensible_target < 0) {
            JS_FreeValue(ctx, trap_result_obj);
            return -1;
        }
        res = js_obj_to_desc(ctx, &result_desc, trap_result_obj);
        JS_FreeValue(ctx, trap_result_obj);
        if (res < 0)
            return -1;

        if (target_desc_ret) {
            /* convert result_desc.flags to defineProperty flags */
            flags1 = result_desc.flags | JS_PROP_HAS_CONFIGURABLE | JS_PROP_HAS_ENUMERABLE;
            if (result_desc.flags & JS_PROP_GETSET)
                flags1 |= JS_PROP_HAS_GET | JS_PROP_HAS_SET;
            else
                flags1 |= JS_PROP_HAS_VALUE | JS_PROP_HAS_WRITABLE;
            /* XXX: not complete check: need to compare value &
               getter/setter as in defineproperty */
            if (!check_define_prop_flags(target_desc.flags, flags1))
                goto fail1;
        } else {
            if (!extensible_target)
                goto fail1;
        }
        if (!(result_desc.flags & JS_PROP_CONFIGURABLE)) {
            if (!target_desc_ret || (target_desc.flags & JS_PROP_CONFIGURABLE))
                goto fail1;
            if ((result_desc.flags &
                 (JS_PROP_GETSET | JS_PROP_WRITABLE)) == 0 &&
                target_desc_ret &&
                (target_desc.flags & JS_PROP_WRITABLE) != 0) {
                /* proxy-missing-checks */
            fail1:
                js_free_desc(ctx, &result_desc);
            fail:
                JS_ThrowTypeError(ctx, "proxy: inconsistent getOwnPropertyDescriptor");
                return -1;
            }
        }
        ret = true;
        if (pdesc) {
            *pdesc = result_desc;
        } else {
            js_free_desc(ctx, &result_desc);
        }
    }
    return ret;
}

static int js_proxy_define_own_property(JSContext *ctx, JSValueConst obj,
                                        JSAtom prop, JSValueConst val,
                                        JSValueConst getter,
                                        JSValueConst setter, int flags)
{
    JSProxyData *s;
    JSValue method, ret1, prop_val, desc_val;
    int res, extensible_target;
    JSObject *p;
    JSValueConst args[3];
    JSPropertyDescriptor desc;
    bool ret, setting_not_configurable;

    s = get_proxy_method(ctx, &method, obj, JS_ATOM_defineProperty);
    if (!s)
        return -1;
    if (JS_IsUndefined(method)) {
        return JS_DefineProperty(ctx, s->target, prop, val, getter, setter, flags);
    }
    prop_val = JS_AtomToValue(ctx, prop);
    if (JS_IsException(prop_val)) {
        JS_FreeValue(ctx, method);
        return -1;
    }
    desc_val = js_create_desc(ctx, val, getter, setter, flags);
    if (JS_IsException(desc_val)) {
        JS_FreeValue(ctx, prop_val);
        JS_FreeValue(ctx, method);
        return -1;
    }
    args[0] = s->target;
    args[1] = prop_val;
    args[2] = desc_val;
    ret1 = JS_CallFree(ctx, method, s->handler, 3, args);
    JS_FreeValue(ctx, prop_val);
    JS_FreeValue(ctx, desc_val);
    if (JS_IsException(ret1))
        return -1;
    ret = JS_ToBoolFree(ctx, ret1);
    if (!ret) {
        if (flags & JS_PROP_THROW) {
            JS_ThrowTypeError(ctx, "proxy: defineProperty exception");
            return -1;
        } else {
            return 0;
        }
    }
    p = JS_VALUE_GET_OBJ(s->target);
    res = JS_GetOwnPropertyInternal(ctx, &desc, p, prop);
    if (res < 0)
        return -1;
    /* must go through IsExtensible(): the target can be a proxy itself, in
       which case its isExtensible trap is observable and may throw */
    extensible_target = JS_IsExtensible(ctx, s->target);
    if (extensible_target < 0) {
        if (res)
            js_free_desc(ctx, &desc);
        return -1;
    }
    setting_not_configurable = ((flags & (JS_PROP_HAS_CONFIGURABLE |
                                          JS_PROP_CONFIGURABLE)) ==
                                JS_PROP_HAS_CONFIGURABLE);
    if (!res) {
        if (!extensible_target || setting_not_configurable)
            goto fail;
    } else {
        if (!check_define_prop_flags(desc.flags, flags) ||
            ((desc.flags & JS_PROP_CONFIGURABLE) && setting_not_configurable)) {
            goto fail1;
        }
        if (flags & (JS_PROP_HAS_GET | JS_PROP_HAS_SET)) {
            if ((desc.flags & (JS_PROP_GETSET | JS_PROP_CONFIGURABLE)) ==
                JS_PROP_GETSET) {
                if ((flags & JS_PROP_HAS_GET) &&
                    !js_same_value(ctx, getter, desc.getter)) {
                    goto fail1;
                }
                if ((flags & JS_PROP_HAS_SET) &&
                    !js_same_value(ctx, setter, desc.setter)) {
                    goto fail1;
                }
            }
        } else if (flags & JS_PROP_HAS_VALUE) {
            if ((desc.flags & (JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE)) ==
                JS_PROP_WRITABLE && !(flags & JS_PROP_WRITABLE)) {
                /* missing-proxy-check feature */
                goto fail1;
            } else if ((desc.flags & (JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE)) == 0 &&
                !js_same_value(ctx, val, desc.value)) {
                goto fail1;
            }
        }
        if (flags & JS_PROP_HAS_WRITABLE) {
            if ((desc.flags & (JS_PROP_GETSET | JS_PROP_CONFIGURABLE |
                               JS_PROP_WRITABLE)) == JS_PROP_WRITABLE) {
                /* proxy-missing-checks */
            fail1:
                js_free_desc(ctx, &desc);
            fail:
                JS_ThrowTypeError(ctx, "proxy: inconsistent defineProperty");
                return -1;
            }
        }
        js_free_desc(ctx, &desc);
    }
    return 1;
}

static int js_proxy_delete_property(JSContext *ctx, JSValueConst obj,
                                    JSAtom atom)
{
    JSProxyData *s;
    JSValue method, ret, atom_val;
    int res2, is_extensible;
    bool res;
    JSValueConst args[2];

    s = get_proxy_method(ctx, &method, obj, JS_ATOM_deleteProperty);
    if (!s)
        return -1;
    if (JS_IsUndefined(method)) {
        return JS_DeleteProperty(ctx, s->target, atom, 0);
    }
    atom_val = JS_AtomToValue(ctx, atom);;
    if (JS_IsException(atom_val)) {
        JS_FreeValue(ctx, method);
        return -1;
    }
    args[0] = s->target;
    args[1] = atom_val;
    ret = JS_CallFree(ctx, method, s->handler, 2, args);
    JS_FreeValue(ctx, atom_val);
    if (JS_IsException(ret))
        return -1;
    res = JS_ToBoolFree(ctx, ret);
    if (res) {
        int desc_flags;
        res2 = JS_GetOwnPropertyFlagsInternal(ctx, &desc_flags, JS_VALUE_GET_OBJ(s->target), atom);
        if (res2 < 0)
            return -1;
        if (res2) {
            if (!(desc_flags & JS_PROP_CONFIGURABLE)) {
                JS_ThrowTypeError(ctx, "proxy: inconsistent deleteProperty");
                return -1;
            }
            is_extensible = JS_IsExtensible(ctx, s->target);
            if (is_extensible < 0)
                return -1;
            if (!is_extensible) {
                /* proxy-missing-checks */
                JS_ThrowTypeError(ctx, "proxy: inconsistent deleteProperty");
                return -1;
            }
        }
    }
    return res;
}

/* return the index of the property or -1 if not found */
static int find_prop_key(const JSPropertyEnum *tab, int n, JSAtom atom)
{
    int i;
    for(i = 0; i < n; i++) {
        if (tab[i].atom == atom)
            return i;
    }
    return -1;
}

static int js_proxy_get_own_property_names(JSContext *ctx,
                                           JSPropertyEnum **ptab,
                                           uint32_t *plen,
                                           JSValueConst obj)
{
    JSProxyData *s;
    JSValue method, prop_array, val;
    uint32_t len, target_len, tab_size, i, len2;
    JSPropertyEnum *tab, *tab2;
    JSAtom atom;
    int res, is_extensible, idx;

    s = get_proxy_method(ctx, &method, obj, JS_ATOM_ownKeys);
    if (!s)
        return -1;
    if (JS_IsUndefined(method)) {
        return JS_GetOwnPropertyNamesInternal(ctx, ptab, plen,
                                      JS_VALUE_GET_OBJ(s->target),
                                      JS_GPN_STRING_MASK | JS_GPN_SYMBOL_MASK);
    }
    prop_array = JS_CallFree(ctx, method, s->handler, 1, vc(&s->target));
    if (JS_IsException(prop_array))
        return -1;
    /* CreateListFromArrayLike() requires an object */
    if (JS_VALUE_GET_TAG(prop_array) != JS_TAG_OBJECT) {
        JS_FreeValue(ctx, prop_array);
        JS_ThrowTypeError(ctx, "proxy: ownKeys must return an object");
        return -1;
    }
    tab = NULL;
    len = 0;
    tab_size = 0;
    tab2 = NULL;
    len2 = 0;
    if (js_get_length32(ctx, &target_len, prop_array))
        goto fail;
    for(i = 0; i < target_len; i++) {
        val = JS_GetPropertyUint32(ctx, prop_array, i);
        if (JS_IsException(val))
            goto fail;
        if (!JS_IsString(val) && !JS_IsSymbol(val)) {
            JS_FreeValue(ctx, val);
            JS_ThrowTypeError(ctx, "proxy: properties must be strings or symbols");
            goto fail;
        }
        atom = JS_ValueToAtom(ctx, val);
        JS_FreeValue(ctx, val);
        if (atom == JS_ATOM_NULL)
            goto fail;
        if (len >= tab_size) {
            int64_t new_size = max_int64(8, tab_size + (int64_t)tab_size / 2);
            JSPropertyEnum *new_tab;
            new_size = min_int64(new_size, target_len);
            if (new_size > (int64_t)(SIZE_MAX / sizeof(tab[0]))) {
                JS_FreeAtom(ctx, atom);
                JS_ThrowOutOfMemory(ctx);
                goto fail;
            }
            new_tab = js_realloc(ctx, tab, sizeof(tab[0]) * (size_t)new_size);
            if (!new_tab) {
                JS_FreeAtom(ctx, atom);
                goto fail;
            }
            tab = new_tab;
            tab_size = new_size;
        }
        tab[len].atom = atom;
        tab[len].is_enumerable = false; /* XXX: redundant? */
        len++;
    }

    /* check duplicate properties (XXX: inefficient, could store the
     * properties an a temporary object to use the hash) */
    for(i = 1; i < len; i++) {
        if (find_prop_key(tab, i, tab[i].atom) >= 0) {
            JS_ThrowTypeError(ctx, "proxy: duplicate property");
            goto fail;
        }
    }

    is_extensible = JS_IsExtensible(ctx, s->target);
    if (is_extensible < 0)
        goto fail;

    /* check if there are non configurable properties */
    if (s->is_revoked) {
        JS_ThrowTypeErrorRevokedProxy(ctx);
        goto fail;
    }
    if (JS_GetOwnPropertyNamesInternal(ctx, &tab2, &len2, JS_VALUE_GET_OBJ(s->target),
                               JS_GPN_STRING_MASK | JS_GPN_SYMBOL_MASK))
        goto fail;
    for(i = 0; i < len2; i++) {
        if (s->is_revoked) {
            JS_ThrowTypeErrorRevokedProxy(ctx);
            goto fail;
        }
        {
            int desc_flags;
            res = JS_GetOwnPropertyFlagsInternal(ctx, &desc_flags, JS_VALUE_GET_OBJ(s->target),
                                    tab2[i].atom);
            if (res < 0)
                goto fail;
            if (res) {  /* safety, property should be found */
                if (!(desc_flags & JS_PROP_CONFIGURABLE) || !is_extensible) {
                    idx = find_prop_key(tab, len, tab2[i].atom);
                    if (idx < 0) {
                        JS_ThrowTypeError(ctx, "proxy: target property must be present in proxy ownKeys");
                        goto fail;
                    }
                    /* mark the property as found */
                    if (!is_extensible)
                        tab[idx].is_enumerable = true;
                }
            }
        }
    }
    if (!is_extensible) {
        /* check that all property in 'tab' were checked */
        for(i = 0; i < len; i++) {
            if (!tab[i].is_enumerable) {
                JS_ThrowTypeError(ctx, "proxy: property not present in target were returned by non extensible proxy");
                goto fail;
            }
        }
    }

    js_free_prop_enum(ctx, tab2, len2);
    JS_FreeValue(ctx, prop_array);
    *ptab = tab;
    *plen = len;
    return 0;
 fail:
    js_free_prop_enum(ctx, tab2, len2);
    js_free_prop_enum(ctx, tab, len);
    JS_FreeValue(ctx, prop_array);
    return -1;
}

static JSValue js_proxy_call_constructor(JSContext *ctx, JSValueConst func_obj,
                                         JSValueConst new_target,
                                         int argc, JSValueConst *argv)
{
    JSProxyData *s;
    JSValue method, arg_array, ret;
    JSValueConst args[3];

    s = get_proxy_method(ctx, &method, func_obj, JS_ATOM_construct);
    if (!s)
        return JS_EXCEPTION;
    if (!JS_IsConstructor(ctx, s->target))
        return JS_ThrowTypeErrorNotAConstructor(ctx, s->target);
    if (JS_IsUndefined(method))
        return JS_CallConstructor2(ctx, s->target, new_target, argc, argv);
    arg_array = js_create_array(ctx, argc, argv);
    if (JS_IsException(arg_array)) {
        ret = JS_EXCEPTION;
        goto fail;
    }
    args[0] = s->target;
    args[1] = arg_array;
    args[2] = new_target;
    ret = JS_Call(ctx, method, s->handler, 3, args);
    if (!JS_IsException(ret) && JS_VALUE_GET_TAG(ret) != JS_TAG_OBJECT) {
        JS_FreeValue(ctx, ret);
        ret = JS_ThrowTypeErrorNotAnObject(ctx);
    }
 fail:
    JS_FreeValue(ctx, method);
    JS_FreeValue(ctx, arg_array);
    return ret;
}

static JSValue js_proxy_call(JSContext *ctx, JSValueConst func_obj,
                             JSValueConst this_obj,
                             int argc, JSValueConst *argv, int flags)
{
    JSProxyData *s;
    JSValue method, arg_array, ret;
    JSValueConst args[3];

    if (flags & JS_CALL_FLAG_CONSTRUCTOR)
        return js_proxy_call_constructor(ctx, func_obj, this_obj, argc, argv);

    s = get_proxy_method(ctx, &method, func_obj, JS_ATOM_apply);
    if (!s)
        return JS_EXCEPTION;
    if (!s->is_func) {
        JS_FreeValue(ctx, method);
        return JS_ThrowTypeErrorNotAFunction(ctx);
    }
    if (JS_IsUndefined(method))
        return JS_Call(ctx, s->target, this_obj, argc, argv);
    arg_array = js_create_array(ctx, argc, argv);
    if (JS_IsException(arg_array)) {
        ret = JS_EXCEPTION;
        goto fail;
    }
    args[0] = s->target;
    args[1] = this_obj;
    args[2] = arg_array;
    ret = JS_Call(ctx, method, s->handler, 3, args);
 fail:
    JS_FreeValue(ctx, method);
    JS_FreeValue(ctx, arg_array);
    return ret;
}

static int js_proxy_isArray(JSContext *ctx, JSValueConst obj)
{
    JSProxyData *s = JS_GetOpaque(obj, JS_CLASS_PROXY);
    if (!s)
        return false;

    if (js_check_stack_overflow(ctx->rt, 0)) {
        JS_ThrowStackOverflow(ctx);
        return -1;
    }

    if (s->is_revoked) {
        JS_ThrowTypeErrorRevokedProxy(ctx);
        return -1;
    }
    return js_is_array(ctx, s->target);
}

static const JSClassExoticMethods js_proxy_exotic_methods = {
    .get_own_property = js_proxy_get_own_property,
    .define_own_property = js_proxy_define_own_property,
    .delete_property = js_proxy_delete_property,
    .get_own_property_names = js_proxy_get_own_property_names,
    .has_property = js_proxy_has,
    .get_property = js_proxy_get,
    .set_property = js_proxy_set,
};

JSValue JS_NewProxy(JSContext *ctx, JSValueConst target, JSValueConst handler)
{
    JSProxyData *s;
    JSValue obj;

    if (JS_VALUE_GET_TAG(target) != JS_TAG_OBJECT ||
        JS_VALUE_GET_TAG(handler) != JS_TAG_OBJECT) {
        return JS_ThrowTypeErrorNotAnObject(ctx);
    }
    obj = JS_NewObjectProtoClass(ctx, JS_NULL, JS_CLASS_PROXY);
    if (JS_IsException(obj))
        return obj;
    s = js_malloc(ctx, sizeof(*s));
    if (!s) {
        JS_FreeValue(ctx, obj);
        return JS_EXCEPTION;
    }
    s->target = js_dup(target);
    s->handler = js_dup(handler);
    s->is_func = JS_IsFunction(ctx, target);
    s->is_revoked = false;
    JS_SetOpaqueInternal(obj, s);
    JS_SetConstructorBit(ctx, obj, JS_IsConstructor(ctx, target));
    return obj;
}

static JSValue js_proxy_constructor(JSContext *ctx, JSValueConst this_val,
                                    int argc, JSValueConst *argv)
{
    return JS_NewProxy(ctx, argv[0], argv[1]);
}

static JSValue js_proxy_revoke(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv, int magic,
                               JSValueConst *func_data)
{
    JSProxyData *s = JS_GetOpaque(func_data[0], JS_CLASS_PROXY);
    if (s) {
        /* We do not free the handler and target in case they are
           referenced as constants in the C call stack */
        s->is_revoked = true;
        JS_FreeValue(ctx, unsafe_unconst(func_data[0]));
        func_data[0] = JS_NULL;
    }
    return JS_UNDEFINED;
}

static JSValue js_proxy_revoke_constructor(JSContext *ctx,
                                           JSValueConst proxy_obj)
{
    return JS_NewCFunctionData(ctx, js_proxy_revoke, 0, 0, 1, &proxy_obj);
}

static JSValue js_proxy_revocable(JSContext *ctx, JSValueConst this_val,
                                 int argc, JSValueConst *argv)
{
    JSValue proxy_obj, revoke_obj = JS_UNDEFINED, obj;

    proxy_obj = js_proxy_constructor(ctx, JS_UNDEFINED, argc, argv);
    if (JS_IsException(proxy_obj))
        goto fail;
    revoke_obj = js_proxy_revoke_constructor(ctx, proxy_obj);
    if (JS_IsException(revoke_obj))
        goto fail;
    obj = JS_NewObject(ctx);
    if (JS_IsException(obj))
        goto fail;
    // XXX: exceptions?
    JS_DefinePropertyValue(ctx, obj, JS_ATOM_proxy, proxy_obj, JS_PROP_C_W_E);
    JS_DefinePropertyValue(ctx, obj, JS_ATOM_revoke, revoke_obj, JS_PROP_C_W_E);
    return obj;
 fail:
    JS_FreeValue(ctx, proxy_obj);
    JS_FreeValue(ctx, revoke_obj);
    return JS_EXCEPTION;
}

static const JSCFunctionListEntry js_proxy_funcs[] = {
    JS_CFUNC_DEF("revocable", 2, js_proxy_revocable ),
};

static const JSClassShortDef js_proxy_class_def[] = {
    { JS_ATOM_Object, js_proxy_finalizer, js_proxy_mark }, /* JS_CLASS_PROXY */
};

int JS_AddIntrinsicProxy(JSContext *ctx)
{
    JSRuntime *rt = ctx->rt;
    JSValue obj1;

    if (!JS_IsRegisteredClass(rt, JS_CLASS_PROXY)) {
        if (init_class_range(rt, js_proxy_class_def, JS_CLASS_PROXY,
                             countof(js_proxy_class_def)))
            return -1;
        rt->class_array[JS_CLASS_PROXY].exotic = &js_proxy_exotic_methods;
        rt->class_array[JS_CLASS_PROXY].call = js_proxy_call;
    }

    /* additional fields: name, length */
    obj1 = JS_NewCFunction3(ctx, js_proxy_constructor, "Proxy", 2,
                            JS_CFUNC_constructor, 0,
                            ctx->function_proto, countof(js_proxy_funcs) + 2);
    if (JS_IsException(obj1))
        return -1;
    JS_SetConstructorBit(ctx, obj1, true);
    if (JS_SetPropertyFunctionList(ctx, obj1, js_proxy_funcs,
                                   countof(js_proxy_funcs)))
        goto fail;
    if (JS_DefinePropertyValueStr(ctx, ctx->global_obj, "Proxy",
                                  obj1, JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE) < 0)
        goto fail;
    return 0;
 fail:
    JS_FreeValue(ctx, obj1);
    return -1;
}

bool JS_IsProxy(JSValueConst val)
{
    if (JS_VALUE_GET_TAG(val) == JS_TAG_OBJECT) {
        JSObject *p = JS_VALUE_GET_OBJ(val);
        return p->class_id == JS_CLASS_PROXY;
    }
    return false;
}

static JSValue js_get_proxy_field(JSContext *ctx, JSValueConst proxy,
                                  int offset)
{
    if (JS_VALUE_GET_TAG(proxy) == JS_TAG_OBJECT) {
        JSObject *p = JS_VALUE_GET_OBJ(proxy);
        if (p->class_id == JS_CLASS_PROXY) {
            JSProxyData *s = JS_GetOpaque(proxy, JS_CLASS_PROXY);
            if (s->is_revoked)
                return JS_ThrowTypeErrorRevokedProxy(ctx);
            return js_dup(*(JSValue *)((char *)s + offset));
        }
    }
    return JS_ThrowTypeError(ctx, "not a proxy");
}

JSValue JS_GetProxyTarget(JSContext *ctx, JSValueConst proxy)
{
    return js_get_proxy_field(ctx, proxy, offsetof(JSProxyData, target));
}

JSValue JS_GetProxyHandler(JSContext *ctx, JSValueConst proxy)
{
    return js_get_proxy_field(ctx, proxy, offsetof(JSProxyData, handler));
}

/* Symbol */

static JSValue js_symbol_constructor(JSContext *ctx, JSValueConst new_target,
                                     int argc, JSValueConst *argv)
{
    JSValue str;
    JSString *p;

    if (!JS_IsUndefined(new_target))
        return JS_ThrowTypeErrorNotAConstructor(ctx, new_target);
    if (argc == 0 || JS_IsUndefined(argv[0])) {
        p = NULL;
    } else {
        str = JS_ToString(ctx, argv[0]);
        if (JS_IsException(str))
            return JS_EXCEPTION;
        p = JS_VALUE_GET_STRING(str);
    }
    return JS_NewSymbolInternal(ctx, p, JS_ATOM_TYPE_SYMBOL);
}

static JSValue js_thisSymbolValue(JSContext *ctx, JSValueConst this_val)
{
    if (JS_VALUE_GET_TAG(this_val) == JS_TAG_SYMBOL)
        return js_dup(this_val);

    if (JS_VALUE_GET_TAG(this_val) == JS_TAG_OBJECT) {
        JSObject *p = JS_VALUE_GET_OBJ(this_val);
        if (p->class_id == JS_CLASS_SYMBOL) {
            if (JS_VALUE_GET_TAG(p->u.object_data) == JS_TAG_SYMBOL)
                return js_dup(p->u.object_data);
        }
    }
    return JS_ThrowTypeError(ctx, "not a symbol");
}

static JSValue js_symbol_toString(JSContext *ctx, JSValueConst this_val,
                                  int argc, JSValueConst *argv)
{
    JSValue val, ret;
    val = js_thisSymbolValue(ctx, this_val);
    if (JS_IsException(val))
        return val;
    /* XXX: use JS_ToStringInternal() with a flags */
    ret = js_string_constructor(ctx, JS_UNDEFINED, 1, vc(&val));
    JS_FreeValue(ctx, val);
    return ret;
}

static JSValue js_symbol_valueOf(JSContext *ctx, JSValueConst this_val,
                                 int argc, JSValueConst *argv)
{
    return js_thisSymbolValue(ctx, this_val);
}

static JSValue js_symbol_get_description(JSContext *ctx, JSValueConst this_val)
{
    JSValue val, ret;
    JSAtomStruct *p;

    val = js_thisSymbolValue(ctx, this_val);
    if (JS_IsException(val))
        return val;
    p = JS_VALUE_GET_PTR(val);
    if (p->len == 0 && p->is_wide_char != 0) {
        ret = JS_UNDEFINED;
    } else {
        ret = JS_AtomToString(ctx, js_get_atom_index(ctx->rt, p));
    }
    JS_FreeValue(ctx, val);
    return ret;
}

static const JSCFunctionListEntry js_symbol_proto_funcs[] = {
    JS_CFUNC_DEF("toString", 0, js_symbol_toString ),
    JS_CFUNC_DEF("valueOf", 0, js_symbol_valueOf ),
    // XXX: should have writable: false
    JS_CFUNC_DEF("[Symbol.toPrimitive]", 1, js_symbol_valueOf ),
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "Symbol", JS_PROP_CONFIGURABLE ),
    JS_CGETSET_DEF("description", js_symbol_get_description, NULL ),
};

static JSValue js_symbol_for(JSContext *ctx, JSValueConst this_val,
                             int argc, JSValueConst *argv)
{
    JSValue str;

    str = JS_ToString(ctx, argv[0]);
    if (JS_IsException(str))
        return JS_EXCEPTION;
    return JS_NewSymbolInternal(ctx, JS_VALUE_GET_STRING(str), JS_ATOM_TYPE_GLOBAL_SYMBOL);
}

static JSValue js_symbol_keyFor(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv)
{
    JSAtomStruct *p;

    if (!JS_IsSymbol(argv[0]))
        return JS_ThrowTypeError(ctx, "not a symbol");
    p = JS_VALUE_GET_PTR(argv[0]);
    if (p->atom_type != JS_ATOM_TYPE_GLOBAL_SYMBOL)
        return JS_UNDEFINED;
    return js_dup(JS_MKPTR(JS_TAG_STRING, p));
}

static const JSCFunctionListEntry js_symbol_funcs[] = {
    JS_CFUNC_DEF("for", 1, js_symbol_for ),
    JS_CFUNC_DEF("keyFor", 1, js_symbol_keyFor ),
    JS_PROP_SYMBOL_DEF("toPrimitive", JS_ATOM_Symbol_toPrimitive, 0),
    JS_PROP_SYMBOL_DEF("iterator", JS_ATOM_Symbol_iterator, 0),
    JS_PROP_SYMBOL_DEF("match", JS_ATOM_Symbol_match, 0),
    JS_PROP_SYMBOL_DEF("matchAll", JS_ATOM_Symbol_matchAll, 0),
    JS_PROP_SYMBOL_DEF("replace", JS_ATOM_Symbol_replace, 0),
    JS_PROP_SYMBOL_DEF("search", JS_ATOM_Symbol_search, 0),
    JS_PROP_SYMBOL_DEF("split", JS_ATOM_Symbol_split, 0),
    JS_PROP_SYMBOL_DEF("toStringTag", JS_ATOM_Symbol_toStringTag, 0),
    JS_PROP_SYMBOL_DEF("isConcatSpreadable", JS_ATOM_Symbol_isConcatSpreadable, 0),
    JS_PROP_SYMBOL_DEF("hasInstance", JS_ATOM_Symbol_hasInstance, 0),
    JS_PROP_SYMBOL_DEF("species", JS_ATOM_Symbol_species, 0),
    JS_PROP_SYMBOL_DEF("unscopables", JS_ATOM_Symbol_unscopables, 0),
    JS_PROP_SYMBOL_DEF("asyncIterator", JS_ATOM_Symbol_asyncIterator, 0),
    JS_PROP_SYMBOL_DEF("dispose", JS_ATOM_Symbol_dispose, 0),
    JS_PROP_SYMBOL_DEF("asyncDispose", JS_ATOM_Symbol_asyncDispose, 0),
};

/* Set/Map/WeakSet/WeakMap */

#define MAGIC_SET (1 << 0)
#define MAGIC_WEAK (1 << 1)

static JSValue js_map_constructor(JSContext *ctx, JSValueConst new_target,
                                  int argc, JSValueConst *argv, int magic)
{
    JSMapState *s;
    JSValue obj, adder = JS_UNDEFINED, iter = JS_UNDEFINED, next_method = JS_UNDEFINED;
    JSValueConst arr;
    bool is_set, is_weak;

    is_set = magic & MAGIC_SET;
    is_weak = ((magic & MAGIC_WEAK) != 0);
    obj = js_create_from_ctor(ctx, new_target, JS_CLASS_MAP + magic);
    if (JS_IsException(obj))
        return JS_EXCEPTION;
    s = js_mallocz(ctx, sizeof(*s));
    if (!s)
        goto fail;
    init_list_head(&s->records);
    s->is_weak = is_weak;
    JS_SetOpaqueInternal(obj, s);
    s->hash_size = 1;
    s->hash_table = js_malloc(ctx, sizeof(s->hash_table[0]) * s->hash_size);
    if (!s->hash_table)
        goto fail;
    init_list_head(&s->hash_table[0]);
    s->record_count_threshold = 4;

    arr = JS_UNDEFINED;
    if (argc > 0)
        arr = argv[0];
    if (!JS_IsUndefined(arr) && !JS_IsNull(arr)) {
        JSValue item, ret;
        int done;

        adder = JS_GetProperty(ctx, obj, is_set ? JS_ATOM_add : JS_ATOM_set);
        if (JS_IsException(adder))
            goto fail;
        if (!JS_IsFunction(ctx, adder)) {
            JS_ThrowTypeError(ctx, "%s is not a function", is_set ? "set" : "add");
            goto fail;
        }

        iter = JS_GetIterator(ctx, arr, false);
        if (JS_IsException(iter))
            goto fail;
        next_method = JS_GetProperty(ctx, iter, JS_ATOM_next);
        if (JS_IsException(next_method))
            goto fail;

        for(;;) {
            item = JS_IteratorNext(ctx, iter, next_method, 0, NULL, &done);
            if (JS_IsException(item))
                goto fail;
            if (done)
                break;
            if (is_set) {
                ret = JS_Call(ctx, adder, obj, 1, vc(&item));
                if (JS_IsException(ret)) {
                    JS_FreeValue(ctx, item);
                    goto fail;
                }
            } else {
                JSValue key, value;
                JSValueConst args[2];
                key = JS_UNDEFINED;
                value = JS_UNDEFINED;
                if (!JS_IsObject(item)) {
                    JS_ThrowTypeErrorNotAnObject(ctx);
                    goto fail1;
                }
                key = JS_GetPropertyUint32(ctx, item, 0);
                if (JS_IsException(key))
                    goto fail1;
                value = JS_GetPropertyUint32(ctx, item, 1);
                if (JS_IsException(value))
                    goto fail1;
                args[0] = key;
                args[1] = value;
                ret = JS_Call(ctx, adder, obj, 2, args);
                if (JS_IsException(ret)) {
                fail1:
                    JS_FreeValue(ctx, item);
                    JS_FreeValue(ctx, key);
                    JS_FreeValue(ctx, value);
                    goto fail;
                }
                JS_FreeValue(ctx, key);
                JS_FreeValue(ctx, value);
            }
            JS_FreeValue(ctx, ret);
            JS_FreeValue(ctx, item);
        }
        JS_FreeValue(ctx, next_method);
        JS_FreeValue(ctx, iter);
        JS_FreeValue(ctx, adder);
    }
    return obj;
 fail:
    if (JS_IsObject(iter)) {
        /* close the iterator object, preserving pending exception */
        JS_IteratorClose(ctx, iter, true);
    }
    JS_FreeValue(ctx, next_method);
    JS_FreeValue(ctx, iter);
    JS_FreeValue(ctx, adder);
    JS_FreeValue(ctx, obj);
    return JS_EXCEPTION;
}

/* XXX: could normalize strings to speed up comparison */
static JSValue map_normalize_key(JSContext *ctx, JSValue key)
{
    uint32_t tag = JS_VALUE_GET_TAG(key);
    // convert -0.0 to +0.0
    // not a leak; |key| and return value are not heap-allocated
    if (JS_TAG_IS_FLOAT64(tag) && JS_VALUE_GET_FLOAT64(key) == 0.0)
        return js_int32(0);
    return key;
}

static JSValueConst map_normalize_key_const(JSContext *ctx, JSValueConst key)
{
    return safe_const(map_normalize_key(ctx, unsafe_unconst(key)));
}

/* XXX: better hash ? */
static uint32_t map_hash_key(JSContext *ctx, JSValueConst key)
{
    uint32_t tag = JS_VALUE_GET_NORM_TAG(key);
    uint32_t h;
    double d;
    JSFloat64Union u;
    JSBigInt *r;

    switch(tag) {
    case JS_TAG_BOOL:
        h = JS_VALUE_GET_INT(key);
        break;
    case JS_TAG_STRING:
        h = hash_string(JS_VALUE_GET_STRING(key), 0);
        break;
    case JS_TAG_STRING_ROPE:
        h = hash_string_rope(key, 0);
        break;
    case JS_TAG_OBJECT:
    case JS_TAG_SYMBOL:
        h = (uintptr_t)JS_VALUE_GET_PTR(key) * 3163;
        break;
    case JS_TAG_INT:
        d = JS_VALUE_GET_INT(key);
        goto hash_float64;
    case JS_TAG_SHORT_BIG_INT:
        d = JS_VALUE_GET_SHORT_BIG_INT(key);
        goto hash_float64;
    case JS_TAG_BIG_INT:
        r = JS_VALUE_GET_PTR(key);
        h = hash_string8((void *)r->tab, r->len * sizeof(*r->tab), 0);
        break;
    case JS_TAG_FLOAT64:
        d = JS_VALUE_GET_FLOAT64(key);
        /* normalize the NaN */
        if (isnan(d))
            d = NAN;
    hash_float64:
        u.d = d;
        h = (u.u32[0] ^ u.u32[1]) * 3163;
        tag = JS_TAG_FLOAT64;
        break;
    default:
        h = 0;
        break;
    }
    return h ^ ctx->hash_seed ^ hash32(tag);
}

static JSMapRecord *map_find_record(JSContext *ctx, JSMapState *s,
                                    JSValueConst key)
{
    struct list_head *el;
    JSMapRecord *mr;
    uint32_t h;
    h = map_hash_key(ctx, key) & (s->hash_size - 1);
    list_for_each(el, &s->hash_table[h]) {
        mr = list_entry(el, JSMapRecord, hash_link);
        if (js_same_value_zero(ctx, mr->key, key))
            return mr;
    }
    return NULL;
}

static void map_hash_resize(JSContext *ctx, JSMapState *s)
{
    uint32_t new_hash_size, i, h;
    struct list_head *new_hash_table, *el;
    JSMapRecord *mr;

    /* XXX: no reporting of memory allocation failure */
    if (s->hash_size == 1)
        new_hash_size = 4;
    else
        new_hash_size = s->hash_size * 2;
    new_hash_table = js_realloc(ctx, s->hash_table,
                                sizeof(new_hash_table[0]) * new_hash_size);
    if (!new_hash_table)
        return;

    for(i = 0; i < new_hash_size; i++)
        init_list_head(&new_hash_table[i]);

    list_for_each(el, &s->records) {
        mr = list_entry(el, JSMapRecord, link);
        if (!mr->empty) {
            h = map_hash_key(ctx, mr->key) & (new_hash_size - 1);
            list_add_tail(&mr->hash_link, &new_hash_table[h]);
        }
    }
    s->hash_table = new_hash_table;
    s->hash_size = new_hash_size;
    s->record_count_threshold = new_hash_size * 2;
}

static JSWeakRefRecord **get_first_weak_ref(JSValueConst key)
{
        switch (JS_VALUE_GET_TAG(key)) {
        case JS_TAG_OBJECT:
            {
                JSObject *p = JS_VALUE_GET_OBJ(key);
                return &p->first_weak_ref;
            }
            break;
        case JS_TAG_SYMBOL:
            {
                JSAtomStruct *p = JS_VALUE_GET_PTR(key);
                return &p->first_weak_ref;
            }
            break;
        default:
            abort();
        }
        return NULL; // pacify compiler
}

static JSMapRecord *map_add_record(JSContext *ctx, JSMapState *s,
                                   JSValueConst key)
{
    uint32_t h;
    JSMapRecord *mr;

    mr = js_malloc(ctx, sizeof(*mr));
    if (!mr)
        return NULL;
    mr->ref_count = 1;
    mr->map = s;
    mr->empty = false;
    if (s->is_weak) {
        JSWeakRefRecord *wr = js_malloc(ctx, sizeof(*wr));
        if (!wr) {
            js_free(ctx, mr);
            return NULL;
        }
        wr->kind = JS_WEAK_REF_KIND_MAP;
        wr->u.map_record = mr;
        insert_weakref_record(key, wr);
        mr->key = unsafe_unconst(key);
    } else {
        mr->key = js_dup(key);
    }
    h = map_hash_key(ctx, key) & (s->hash_size - 1);
    list_add_tail(&mr->hash_link, &s->hash_table[h]);
    list_add_tail(&mr->link, &s->records);
    s->record_count++;
    if (s->record_count >= s->record_count_threshold) {
        map_hash_resize(ctx, s);
    }
    return mr;
}

/* Remove the weak reference from the object weak
   reference list. we don't use a doubly linked list to
   save space, assuming a given object has few weak
       references to it */
static void delete_map_weak_ref(JSRuntime *rt, JSMapRecord *mr)
{
    JSWeakRefRecord **pwr, *wr;

    pwr = get_first_weak_ref(mr->key);
    for(;;) {
        wr = *pwr;
        assert(wr != NULL);
        if (wr->kind == JS_WEAK_REF_KIND_MAP && wr->u.map_record == mr)
            break;
        pwr = &wr->next_weak_ref;
    }
    *pwr = wr->next_weak_ref;
    js_free_rt(rt, wr);
}

static void map_delete_record(JSRuntime *rt, JSMapState *s, JSMapRecord *mr)
{
    if (mr->empty)
        return;
    list_del(&mr->hash_link);
    if (s->is_weak) {
        delete_map_weak_ref(rt, mr);
    } else {
        JS_FreeValueRT(rt, mr->key);
    }
    JS_FreeValueRT(rt, mr->value);
    if (--mr->ref_count == 0) {
        list_del(&mr->link);
        js_free_rt(rt, mr);
    } else {
        /* keep a zombie record for iterators */
        mr->empty = true;
        mr->key = JS_UNDEFINED;
        mr->value = JS_UNDEFINED;
    }
    s->record_count--;
}

static void map_decref_record(JSRuntime *rt, JSMapRecord *mr)
{
    if (--mr->ref_count == 0) {
        /* the record can be safely removed */
        assert(mr->empty);
        list_del(&mr->link);
        js_free_rt(rt, mr);
    }
}

static JSValue js_map_set(JSContext *ctx, JSValueConst this_val,
                          int argc, JSValueConst *argv, int magic)
{
    JSMapState *s = JS_GetOpaque2(ctx, this_val, JS_CLASS_MAP + magic);
    JSMapRecord *mr;
    JSValueConst key, value;
    int is_set;

    if (!s)
        return JS_EXCEPTION;
    is_set = (magic & MAGIC_SET);
    key = map_normalize_key_const(ctx, argv[0]);
    if (s->is_weak && !is_valid_weakref_target(key))
        return JS_ThrowTypeError(ctx, "invalid value used as %s key", is_set ? "WeakSet" : "WeakMap");
    if (is_set)
        value = JS_UNDEFINED;
    else
        value = argv[1];
    mr = map_find_record(ctx, s, key);
    if (mr) {
        JS_FreeValue(ctx, mr->value);
    } else {
        mr = map_add_record(ctx, s, key);
        if (!mr)
            return JS_EXCEPTION;
    }
    mr->value = js_dup(value);
    return js_dup(this_val);
}

static JSValue js_map_get(JSContext *ctx, JSValueConst this_val,
                          int argc, JSValueConst *argv, int magic)
{
    JSMapState *s = JS_GetOpaque2(ctx, this_val, JS_CLASS_MAP + magic);
    JSMapRecord *mr;
    JSValueConst key;

    if (!s)
        return JS_EXCEPTION;
    key = map_normalize_key_const(ctx, argv[0]);
    mr = map_find_record(ctx, s, key);
    if (!mr)
        return JS_UNDEFINED;
    else
        return js_dup(mr->value);
}

static JSValue js_map_getOrInsert(JSContext *ctx, JSValueConst this_val,
                                  int argc, JSValueConst *argv, int magic)
{
    bool computed = magic & 1;
    JSClassID class_id = magic >> 1;
    JSMapState *s = JS_GetOpaque2(ctx, this_val, class_id);
    JSMapRecord *mr;
    JSValueConst key;
    JSValue value;

    if (!s)
        return JS_EXCEPTION;
    if (computed && check_function(ctx, argv[1]))
        return JS_EXCEPTION;
    key = map_normalize_key_const(ctx, argv[0]);
    if (s->is_weak && !is_valid_weakref_target(key))
        return JS_ThrowTypeError(ctx, "invalid value used as WeakMap key");
    mr = map_find_record(ctx, s, key);
    if (!mr) {
        if (computed) {
            value = JS_Call(ctx, argv[1], JS_UNDEFINED, 1, &key);
            if (JS_IsException(value))
                return JS_EXCEPTION;
            mr = map_find_record(ctx, s, key);
            if (mr)
                map_delete_record(ctx->rt, s, mr);
        } else {
            value = js_dup(argv[1]);
        }
        mr = map_add_record(ctx, s, key);
        if (!mr) {
            JS_FreeValue(ctx, value);
            return JS_EXCEPTION;
        }
        mr->value = value;
    }
    return js_dup(mr->value);
}

static JSValue js_map_has(JSContext *ctx, JSValueConst this_val,
                          int argc, JSValueConst *argv, int magic)
{
    JSMapState *s = JS_GetOpaque2(ctx, this_val, JS_CLASS_MAP + magic);
    JSMapRecord *mr;
    JSValueConst key;

    if (!s)
        return JS_EXCEPTION;
    key = map_normalize_key_const(ctx, argv[0]);
    mr = map_find_record(ctx, s, key);
    return js_bool(mr != NULL);
}

static JSValue js_map_delete(JSContext *ctx, JSValueConst this_val,
                             int argc, JSValueConst *argv, int magic)
{
    JSMapState *s = JS_GetOpaque2(ctx, this_val, JS_CLASS_MAP + magic);
    JSMapRecord *mr;
    JSValueConst key;

    if (!s)
        return JS_EXCEPTION;
    key = map_normalize_key_const(ctx, argv[0]);
    mr = map_find_record(ctx, s, key);
    if (!mr)
        return JS_FALSE;
    map_delete_record(ctx->rt, s, mr);
    return JS_TRUE;
}

static JSValue js_map_clear(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv, int magic)
{
    JSMapState *s = JS_GetOpaque2(ctx, this_val, JS_CLASS_MAP + magic);
    struct list_head *el, *el1;
    JSMapRecord *mr;

    if (!s)
        return JS_EXCEPTION;
    list_for_each_safe(el, el1, &s->records) {
        mr = list_entry(el, JSMapRecord, link);
        map_delete_record(ctx->rt, s, mr);
    }
    return JS_UNDEFINED;
}

static JSValue js_map_get_size(JSContext *ctx, JSValueConst this_val, int magic)
{
    JSMapState *s = JS_GetOpaque2(ctx, this_val, JS_CLASS_MAP + magic);
    if (!s)
        return JS_EXCEPTION;
    return js_uint32(s->record_count);
}

static JSValue js_map_forEach(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv, int magic)
{
    JSMapState *s = JS_GetOpaque2(ctx, this_val, JS_CLASS_MAP + magic);
    JSValueConst func, this_arg;
    JSValue ret, args[3];
    struct list_head *el;
    JSMapRecord *mr;

    if (!s)
        return JS_EXCEPTION;
    func = argv[0];
    if (argc > 1)
        this_arg = argv[1];
    else
        this_arg = JS_UNDEFINED;
    if (check_function(ctx, func))
        return JS_EXCEPTION;
    /* Note: the list can be modified while traversing it, but the
       current element is locked */
    el = s->records.next;
    while (el != &s->records) {
        mr = list_entry(el, JSMapRecord, link);
        if (!mr->empty) {
            mr->ref_count++;
            /* must duplicate in case the record is deleted */
            args[1] = js_dup(mr->key);
            if (magic)
                args[0] = args[1];
            else
                args[0] = js_dup(mr->value);
            args[2] = unsafe_unconst(this_val);
            ret = JS_Call(ctx, func, this_arg, 3, vc(args));
            JS_FreeValue(ctx, args[0]);
            if (!magic)
                JS_FreeValue(ctx, args[1]);
            el = el->next;
            map_decref_record(ctx->rt, mr);
            if (JS_IsException(ret))
                return ret;
            JS_FreeValue(ctx, ret);
        } else {
            el = el->next;
        }
    }
    return JS_UNDEFINED;
}

static JSValue js_map_groupBy(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv)
{
    JSValue res, iter, next, groups, k, v, prop;
    JSValueConst cb, args[2];
    int64_t idx;
    int done;

    // "is function?" check must be observed before argv[0] is accessed
    cb = argv[1];
    if (check_function(ctx, cb))
        return JS_EXCEPTION;

    iter = JS_GetIterator(ctx, argv[0], /*is_async*/false);
    if (JS_IsException(iter))
        return JS_EXCEPTION;

    k = JS_UNDEFINED;
    v = JS_UNDEFINED;
    prop = JS_UNDEFINED;
    groups = JS_UNDEFINED;

    next = JS_GetProperty(ctx, iter, JS_ATOM_next);
    if (JS_IsException(next))
        goto exception;

    groups = js_map_constructor(ctx, JS_UNDEFINED, 0, NULL, 0);
    if (JS_IsException(groups))
        goto exception;

    for (idx = 0; ; idx++) {
        v = JS_IteratorNext(ctx, iter, next, 0, NULL, &done);
        if (JS_IsException(v))
            goto exception;
        if (done)
            break; // v is JS_UNDEFINED

        args[0] = v;
        args[1] = js_int64(idx);
        k = JS_Call(ctx, cb, ctx->global_obj, 2, args);
        if (JS_IsException(k))
            goto exception;

        prop = js_map_get(ctx, groups, 1, vc(&k), 0);
        if (JS_IsException(prop))
            goto exception;

        if (JS_IsUndefined(prop)) {
            prop = JS_NewArray(ctx);
            if (JS_IsException(prop))
                goto exception;
            args[0] = k;
            args[1] = prop;
            res = js_map_set(ctx, groups, 2, args, 0);
            if (JS_IsException(res))
                goto exception;
            JS_FreeValue(ctx, res);
        }

        res = js_array_push(ctx, prop, 1, vc(&v), /*unshift*/0);
        if (JS_IsException(res))
            goto exception;
        // res is an int64

        JS_FreeValue(ctx, prop);
        JS_FreeValue(ctx, k);
        JS_FreeValue(ctx, v);
        prop = JS_UNDEFINED;
        k = JS_UNDEFINED;
        v = JS_UNDEFINED;
    }

    JS_FreeValue(ctx, iter);
    JS_FreeValue(ctx, next);
    return groups;

exception:
    JS_FreeValue(ctx, prop);
    JS_FreeValue(ctx, k);
    JS_FreeValue(ctx, v);
    JS_FreeValue(ctx, groups);
    JS_FreeValue(ctx, iter);
    JS_FreeValue(ctx, next);
    return JS_EXCEPTION;
}

static void js_map_finalizer(JSRuntime *rt, JSValueConst val)
{
    JSObject *p;
    JSMapState *s;
    struct list_head *el, *el1;
    JSMapRecord *mr;

    p = JS_VALUE_GET_OBJ(val);
    s = p->u.map_state;
    if (s) {
        /* if the object is deleted we are sure that no iterator is
           using it */
        list_for_each_safe(el, el1, &s->records) {
            mr = list_entry(el, JSMapRecord, link);
            if (!mr->empty) {
                if (s->is_weak)
                    delete_map_weak_ref(rt, mr);
                else
                    JS_FreeValueRT(rt, mr->key);
                JS_FreeValueRT(rt, mr->value);
            }
            js_free_rt(rt, mr);
        }
        js_free_rt(rt, s->hash_table);
        js_free_rt(rt, s);
    }
}

static void js_map_mark(JSRuntime *rt, JSValueConst val,
                        JS_MarkFunc *mark_func)
{
    JSObject *p = JS_VALUE_GET_OBJ(val);
    JSMapState *s;
    struct list_head *el;
    JSMapRecord *mr;

    s = p->u.map_state;
    if (s) {
        assert(!s->is_weak);
        list_for_each(el, &s->records) {
            mr = list_entry(el, JSMapRecord, link);
            JS_MarkValue(rt, mr->key, mark_func);
            JS_MarkValue(rt, mr->value, mark_func);
        }
    }
}

/* Map Iterator */

typedef struct JSMapIteratorData {
    JSValue obj;
    JSIteratorKindEnum kind;
    JSMapRecord *cur_record;
} JSMapIteratorData;

static void js_map_iterator_finalizer(JSRuntime *rt, JSValueConst val)
{
    JSObject *p;
    JSMapIteratorData *it;

    p = JS_VALUE_GET_OBJ(val);
    it = p->u.map_iterator_data;
    if (it) {
        /* During the GC sweep phase the Map finalizer may be
           called before the Map iterator finalizer */
        if (JS_IsLiveObject(rt, it->obj) && it->cur_record) {
            map_decref_record(rt, it->cur_record);
        }
        JS_FreeValueRT(rt, it->obj);
        js_free_rt(rt, it);
    }
}

static void js_map_iterator_mark(JSRuntime *rt, JSValueConst val,
                                 JS_MarkFunc *mark_func)
{
    JSObject *p = JS_VALUE_GET_OBJ(val);
    JSMapIteratorData *it;
    it = p->u.map_iterator_data;
    if (it) {
        /* the record is already marked by the object */
        JS_MarkValue(rt, it->obj, mark_func);
    }
}

static JSValue js_create_map_iterator(JSContext *ctx, JSValueConst this_val,
                                      int argc, JSValueConst *argv, int magic)
{
    JSIteratorKindEnum kind;
    JSMapState *s;
    JSMapIteratorData *it;
    JSValue enum_obj;

    kind = magic >> 2;
    magic &= 3;
    s = JS_GetOpaque2(ctx, this_val, JS_CLASS_MAP + magic);
    if (!s)
        return JS_EXCEPTION;
    enum_obj = JS_NewObjectClass(ctx, JS_CLASS_MAP_ITERATOR + magic);
    if (JS_IsException(enum_obj))
        goto fail;
    it = js_malloc(ctx, sizeof(*it));
    if (!it) {
        JS_FreeValue(ctx, enum_obj);
        goto fail;
    }
    it->obj = js_dup(this_val);
    it->kind = kind;
    it->cur_record = NULL;
    JS_SetOpaqueInternal(enum_obj, it);
    return enum_obj;
 fail:
    return JS_EXCEPTION;
}

static JSValue js_map_iterator_next(JSContext *ctx, JSValueConst this_val,
                                    int argc, JSValueConst *argv,
                                    int *pdone, int magic)
{
    JSMapIteratorData *it;
    JSMapState *s;
    JSMapRecord *mr;
    struct list_head *el;

    it = JS_GetOpaque2(ctx, this_val, JS_CLASS_MAP_ITERATOR + magic);
    if (!it) {
        *pdone = false;
        return JS_EXCEPTION;
    }
    if (JS_IsUndefined(it->obj))
        goto done;
    s = JS_GetOpaque(it->obj, JS_CLASS_MAP + magic);
    assert(s != NULL);
    if (!it->cur_record) {
        el = s->records.next;
    } else {
        mr = it->cur_record;
        el = mr->link.next;
        map_decref_record(ctx->rt, mr); /* the record can be freed here */
    }
    for(;;) {
        if (el == &s->records) {
            /* no more record  */
            it->cur_record = NULL;
            JS_FreeValue(ctx, it->obj);
            it->obj = JS_UNDEFINED;
        done:
            /* end of enumeration */
            *pdone = true;
            return JS_UNDEFINED;
        }
        mr = list_entry(el, JSMapRecord, link);
        if (!mr->empty)
            break;
        /* get the next record */
        el = mr->link.next;
    }

    /* lock the record so that it won't be freed */
    mr->ref_count++;
    it->cur_record = mr;
    *pdone = false;

    if (it->kind == JS_ITERATOR_KIND_KEY) {
        return js_dup(mr->key);
    } else {
        JSValueConst args[2];
        args[0] = mr->key;
        if (magic)
            args[1] = mr->key;
        else
            args[1] = mr->value;
        if (it->kind == JS_ITERATOR_KIND_VALUE) {
            return js_dup(args[1]);
        } else {
            return js_create_array(ctx, 2, args);
        }
    }
}

static JSValue js_map_read(BCReaderState *s, int magic)
{
    JSContext *ctx = s->ctx;
    JSValue obj, rv, argv[2];
    uint32_t i, prop_count;

    argv[0] = JS_UNDEFINED;
    argv[1] = JS_UNDEFINED;
    obj = js_map_constructor(ctx, JS_UNDEFINED, 0, NULL, magic);
    if (JS_IsException(obj))
        return JS_EXCEPTION;
    if (BC_add_object_ref(s, obj))
        goto fail;
    if (bc_get_leb128(s, &prop_count))
        goto fail;
    for(i = 0; i < prop_count; i++) {
        argv[0] = JS_ReadObjectRec(s);
        if (JS_IsException(argv[0]))
            goto fail;
        if (!(magic & MAGIC_SET)) {
            argv[1] = JS_ReadObjectRec(s);
            if (JS_IsException(argv[1]))
                goto fail;
        }
        rv = js_map_set(ctx, obj, countof(argv), vc(argv), magic);
        if (JS_IsException(rv))
            goto fail;
        JS_FreeValue(ctx, rv);
        JS_FreeValue(ctx, argv[0]);
        JS_FreeValue(ctx, argv[1]);
        argv[0] = JS_UNDEFINED;
        argv[1] = JS_UNDEFINED;
    }
    return obj;
 fail:
    JS_FreeValue(ctx, obj);
    JS_FreeValue(ctx, argv[0]);
    JS_FreeValue(ctx, argv[1]);
    return JS_EXCEPTION;
}

static int js_map_write(BCWriterState *s, struct JSMapState *map_state,
                        int magic)
{
    struct list_head *el;
    JSMapRecord *mr;

    bc_put_leb128(s, map_state ? map_state->record_count : 0);
    if (map_state) {
        list_for_each(el, &map_state->records) {
            mr = list_entry(el, JSMapRecord, link);
            if (JS_WriteObjectRec(s, mr->key))
                return -1;
            // mr->value is always JS_UNDEFINED for sets
            if (!(magic & MAGIC_SET))
                if (JS_WriteObjectRec(s, mr->value))
                    return -1;
        }
    }

    return 0;
}

static JSValue JS_ReadMap(BCReaderState *s)
{
    return js_map_read(s, 0);
}

static JSValue JS_ReadSet(BCReaderState *s)
{
    return js_map_read(s, MAGIC_SET);
}

static int JS_WriteMap(BCWriterState *s, struct JSMapState *map_state)
{
    return js_map_write(s, map_state, 0);
}

static int JS_WriteSet(BCWriterState *s, struct JSMapState *map_state)
{
    return js_map_write(s, map_state, MAGIC_SET);
}

static int js_setlike_get_props(JSContext *ctx, JSValueConst setlike,
                                uint64_t *psize, JSValue *phas, JSValue *pkeys)
{
    JSValue has, keys, v;
    JSMapState *s;
    uint64_t size;
    double d;

    keys = JS_UNDEFINED;
    has = JS_UNDEFINED;
    s = JS_GetOpaque(setlike, JS_CLASS_SET);
    if (s) {
        size = s->record_count;
    } else {
        v = JS_GetProperty(ctx, setlike, JS_ATOM_size);
        if (JS_IsException(v))
            return -1;
        if (JS_IsUndefined(v)) {
            JS_ThrowTypeError(ctx, ".size is undefined");
            return -1;
        }
        if (JS_ToFloat64Free(ctx, &d, v) < 0)
            return -1;
        if (d < 0) {
            JS_ThrowRangeError(ctx, ".size is not a legal size");
            return -1;
        }
        if (isnan(d)) {
            JS_ThrowTypeError(ctx, ".size is not a legal size");
            return -1;
        }
        if (isinf(d) || d > (double)MAX_SAFE_INTEGER) {
            size = UINT64_MAX;
        } else {
            size = (uint64_t)d; // cast for expository reasons
        }
    }
    has = JS_GetProperty(ctx, setlike, JS_ATOM_has);
    if (JS_IsException(has))
        return -1;
    if (!JS_IsFunction(ctx, has)) {
        JS_ThrowTypeError(ctx, ".has is not a function");
        goto fail;
    }
    keys = JS_GetProperty(ctx, setlike, JS_ATOM_keys);
    if (JS_IsException(keys))
        goto fail;
    if (!JS_IsFunction(ctx, keys)) {
        JS_ThrowTypeError(ctx, ".keys is not a function");
        goto fail;
    }
    *psize = size;
    *phas = has;
    *pkeys = keys;
    return 0;
fail:
    JS_FreeValue(ctx, has);
    JS_FreeValue(ctx, keys);
    return -1;
}

static JSValue js_set_isDisjointFrom(JSContext *ctx, JSValueConst this_val,
                                     int argc, JSValueConst *argv)
{
    JSValue has, item, iter, keys, next, rv, rval;
    JSValueConst setlike;
    int done;
    bool found;
    JSMapState *s;
    uint64_t size;
    int ok;

    s = JS_GetOpaque2(ctx, this_val, JS_CLASS_SET);
    if (!s)
        return JS_EXCEPTION;
    setlike = argv[0];
    if (js_setlike_get_props(ctx, setlike, &size, &has, &keys) < 0)
        return JS_EXCEPTION;
    iter = JS_UNDEFINED;
    next = JS_UNDEFINED;
    rval = JS_EXCEPTION;
    if (s->record_count > size) {
        iter = JS_Call(ctx, keys, setlike, 0, NULL);
        if (JS_IsException(iter))
            goto exception;
        next = JS_GetProperty(ctx, iter, JS_ATOM_next);
        if (JS_IsException(next))
            goto exception;
        found = false;
        for (;;) {
            item = JS_IteratorNext(ctx, iter, next, 0, NULL, &done);
            if (JS_IsException(item))
                goto exception;
            if (done) // item is JS_UNDEFINED
                break;
            item = map_normalize_key(ctx, item);
            found = (NULL != map_find_record(ctx, s, item));
            JS_FreeValue(ctx, item);
            if (!found)
                continue;
            if (JS_IteratorClose(ctx, iter, /*is_exception_pending*/false) < 0)
                goto exception;
            break;
        }
    } else {
        iter = js_create_map_iterator(ctx, this_val, 0, NULL, MAGIC_SET);
        if (JS_IsException(iter))
            goto exception;
        found = false;
        do {
            item = js_map_iterator_next(ctx, iter, 0, NULL, &done, MAGIC_SET);
            if (JS_IsException(item))
                goto exception;
            if (done) // item is JS_UNDEFINED
                break;
            rv = JS_Call(ctx, has, setlike, 1, vc(&item));
            JS_FreeValue(ctx, item);
            ok = JS_ToBoolFree(ctx, rv); // returns -1 if rv is JS_EXCEPTION
            if (ok < 0)
                goto exception;
            found = (ok > 0);
        } while (!found);
    }
    rval = !found ? JS_TRUE : JS_FALSE;
exception:
    JS_FreeValue(ctx, has);
    JS_FreeValue(ctx, keys);
    JS_FreeValue(ctx, iter);
    JS_FreeValue(ctx, next);
    return rval;
}

static JSValue js_set_isSubsetOf(JSContext *ctx, JSValueConst this_val,
                                 int argc, JSValueConst *argv)
{
    JSValue has, item, iter, keys, next, rv, rval;
    JSValueConst setlike;
    bool found;
    JSMapState *s;
    uint64_t size;
    int done, ok;

    s = JS_GetOpaque2(ctx, this_val, JS_CLASS_SET);
    if (!s)
        return JS_EXCEPTION;
    setlike = argv[0];
    if (js_setlike_get_props(ctx, setlike, &size, &has, &keys) < 0)
        return JS_EXCEPTION;
    iter = JS_UNDEFINED;
    next = JS_UNDEFINED;
    rval = JS_EXCEPTION;
    found = false;
    if (s->record_count > size)
        goto fini;
    iter = js_create_map_iterator(ctx, this_val, 0, NULL, MAGIC_SET);
    if (JS_IsException(iter))
        goto exception;
    found = true;
    do {
        item = js_map_iterator_next(ctx, iter, 0, NULL, &done, MAGIC_SET);
        if (JS_IsException(item))
            goto exception;
        if (done) // item is JS_UNDEFINED
            break;
        rv = JS_Call(ctx, has, setlike, 1, vc(&item));
        JS_FreeValue(ctx, item);
        ok = JS_ToBoolFree(ctx, rv); // returns -1 if rv is JS_EXCEPTION
        if (ok < 0)
            goto exception;
        found = (ok > 0);
    } while (found);
fini:
    rval = found ? JS_TRUE : JS_FALSE;
exception:
    JS_FreeValue(ctx, has);
    JS_FreeValue(ctx, keys);
    JS_FreeValue(ctx, iter);
    JS_FreeValue(ctx, next);
    return rval;
}

static JSValue js_set_isSupersetOf(JSContext *ctx, JSValueConst this_val,
                                   int argc, JSValueConst *argv)
{
    JSValue has, item, iter, keys, next, rval;
    JSValueConst setlike;
    int done;
    bool found;
    JSMapState *s;
    uint64_t size;

    s = JS_GetOpaque2(ctx, this_val, JS_CLASS_SET);
    if (!s)
        return JS_EXCEPTION;
    setlike = argv[0];
    if (js_setlike_get_props(ctx, setlike, &size, &has, &keys) < 0)
        return JS_EXCEPTION;
    iter = JS_UNDEFINED;
    next = JS_UNDEFINED;
    rval = JS_EXCEPTION;
    found = false;
    if (s->record_count < size)
        goto fini;
    iter = JS_Call(ctx, keys, setlike, 0, NULL);
    if (JS_IsException(iter))
        goto exception;
    next = JS_GetProperty(ctx, iter, JS_ATOM_next);
    if (JS_IsException(next))
        goto exception;
    found = true;
    for (;;) {
        item = JS_IteratorNext(ctx, iter, next, 0, NULL, &done);
        if (JS_IsException(item))
            goto exception;
        if (done) // item is JS_UNDEFINED
            break;
        item = map_normalize_key(ctx, item);
        found = (NULL != map_find_record(ctx, s, item));
        JS_FreeValue(ctx, item);
        if (found)
            continue;
        if (JS_IteratorClose(ctx, iter, /*is_exception_pending*/false) < 0)
            goto exception;
        break;
    }
fini:
    rval = found ? JS_TRUE : JS_FALSE;
exception:
    JS_FreeValue(ctx, has);
    JS_FreeValue(ctx, keys);
    JS_FreeValue(ctx, iter);
    JS_FreeValue(ctx, next);
    return rval;
}

static JSValue js_set_intersection(JSContext *ctx, JSValueConst this_val,
                                   int argc, JSValueConst *argv)
{
    JSValue has, item, iter, keys, newset, next, rv;
    JSValueConst setlike;
    JSMapState *s, *t;
    JSMapRecord *mr;
    uint64_t size;
    int done, ok;

    s = JS_GetOpaque2(ctx, this_val, JS_CLASS_SET);
    if (!s)
        return JS_EXCEPTION;
    setlike = argv[0];
    if (js_setlike_get_props(ctx, setlike, &size, &has, &keys) < 0)
        return JS_EXCEPTION;
    iter = JS_UNDEFINED;
    next = JS_UNDEFINED;
    newset = JS_UNDEFINED;
    if (s->record_count > size) {
        iter = JS_Call(ctx, keys, setlike, 0, NULL);
        if (JS_IsException(iter))
            goto exception;
        next = JS_GetProperty(ctx, iter, JS_ATOM_next);
        if (JS_IsException(next))
            goto exception;
        newset = js_map_constructor(ctx, JS_UNDEFINED, 0, NULL, MAGIC_SET);
        if (JS_IsException(newset))
            goto exception;
        t = JS_GetOpaque(newset, JS_CLASS_SET);
        for (;;) {
            item = JS_IteratorNext(ctx, iter, next, 0, NULL, &done);
            if (JS_IsException(item))
                goto exception;
            if (done) // item is JS_UNDEFINED
                break;
            item = map_normalize_key(ctx, item);
            if (!map_find_record(ctx, s, item)) {
                JS_FreeValue(ctx, item);
            } else if (map_find_record(ctx, t, item)) {
                JS_FreeValue(ctx, item); // no duplicates
            } else if ((mr = map_add_record(ctx, t, item))) {
                JS_FreeValue(ctx, item);
                mr->value = JS_UNDEFINED;
            } else {
                JS_FreeValue(ctx, item);
                goto exception;
            }
        }
    } else {
        iter = js_create_map_iterator(ctx, this_val, 0, NULL, MAGIC_SET);
        if (JS_IsException(iter))
            goto exception;
        newset = js_map_constructor(ctx, JS_UNDEFINED, 0, NULL, MAGIC_SET);
        if (JS_IsException(newset))
            goto exception;
        t = JS_GetOpaque(newset, JS_CLASS_SET);
        for (;;) {
            item = js_map_iterator_next(ctx, iter, 0, NULL, &done, MAGIC_SET);
            if (JS_IsException(item))
                goto exception;
            if (done) // item is JS_UNDEFINED
                break;
            rv = JS_Call(ctx, has, setlike, 1, vc(&item));
            ok = JS_ToBoolFree(ctx, rv); // returns -1 if rv is JS_EXCEPTION
            if (ok > 0) {
                item = map_normalize_key(ctx, item);
                if (map_find_record(ctx, t, item)) {
                    JS_FreeValue(ctx, item); // no duplicates
                } else if ((mr = map_add_record(ctx, t, item))) {
                    JS_FreeValue(ctx, item);
                    mr->value = JS_UNDEFINED;
                } else {
                    JS_FreeValue(ctx, item);
                    goto exception;
                }
            } else {
                JS_FreeValue(ctx, item);
                if (ok < 0)
                    goto exception;
            }
        }
    }
    goto fini;
exception:
    JS_FreeValue(ctx, newset);
    newset = JS_EXCEPTION;
fini:
    JS_FreeValue(ctx, has);
    JS_FreeValue(ctx, keys);
    JS_FreeValue(ctx, iter);
    JS_FreeValue(ctx, next);
    return newset;
}

static JSValue js_set_difference(JSContext *ctx, JSValueConst this_val,
                                 int argc, JSValueConst *argv)
{
    JSValue has, item, iter, keys, newset, next, rv;
    JSValueConst setlike;
    JSMapState *s, *t;
    JSMapRecord *mr;
    uint64_t size;
    int done;
    int ok;

    s = JS_GetOpaque2(ctx, this_val, JS_CLASS_SET);
    if (!s)
        return JS_EXCEPTION;
    setlike = argv[0];
    if (js_setlike_get_props(ctx, setlike, &size, &has, &keys) < 0)
        return JS_EXCEPTION;
    iter = JS_UNDEFINED;
    next = JS_UNDEFINED;
    newset = JS_UNDEFINED;
    if (s->record_count > size) {
        iter = JS_Call(ctx, keys, setlike, 0, NULL);
        if (JS_IsException(iter))
            goto exception;
        next = JS_GetProperty(ctx, iter, JS_ATOM_next);
        if (JS_IsException(next))
            goto exception;
        newset = js_map_constructor(ctx, JS_UNDEFINED, 1, &this_val, MAGIC_SET);
        if (JS_IsException(newset))
            goto exception;
        t = JS_GetOpaque(newset, JS_CLASS_SET);
        for (;;) {
            item = JS_IteratorNext(ctx, iter, next, 0, NULL, &done);
            if (JS_IsException(item))
                goto exception;
            if (done) // item is JS_UNDEFINED
                break;
            item = map_normalize_key(ctx, item);
            mr = map_find_record(ctx, t, item);
            if (mr)
                map_delete_record(ctx->rt, t, mr);
            JS_FreeValue(ctx, item);
        }
    } else {
        iter = js_create_map_iterator(ctx, this_val, 0, NULL, MAGIC_SET);
        if (JS_IsException(iter))
            goto exception;
        newset = js_map_constructor(ctx, JS_UNDEFINED, 0, NULL, MAGIC_SET);
        if (JS_IsException(newset))
            goto exception;
        t = JS_GetOpaque(newset, JS_CLASS_SET);
        for (;;) {
            item = js_map_iterator_next(ctx, iter, 0, NULL, &done, MAGIC_SET);
            if (JS_IsException(item))
                goto exception;
            if (done) // item is JS_UNDEFINED
                break;
            rv = JS_Call(ctx, has, setlike, 1, vc(&item));
            ok = JS_ToBoolFree(ctx, rv); // returns -1 if rv is JS_EXCEPTION
            if (ok == 0) {
                item = map_normalize_key(ctx, item);
                if (map_find_record(ctx, t, item)) {
                    JS_FreeValue(ctx, item); // no duplicates
                } else if ((mr = map_add_record(ctx, t, item))) {
                    JS_FreeValue(ctx, item);
                    mr->value = JS_UNDEFINED;
                } else {
                    JS_FreeValue(ctx, item);
                    goto exception;
                }
            } else {
                JS_FreeValue(ctx, item);
                if (ok < 0)
                    goto exception;
            }
        }
    }
    goto fini;
exception:
    JS_FreeValue(ctx, newset);
    newset = JS_EXCEPTION;
fini:
    JS_FreeValue(ctx, has);
    JS_FreeValue(ctx, keys);
    JS_FreeValue(ctx, iter);
    JS_FreeValue(ctx, next);
    return newset;
}

static JSValue js_set_symmetricDifference(JSContext *ctx, JSValueConst this_val,
                                          int argc, JSValueConst *argv)
{
    JSValue has, item, iter, keys, newset, next;
    JSValueConst setlike;
    struct list_head *el;
    JSMapState *s, *t;
    JSMapRecord *mr;
    uint64_t size;
    int done;
    bool present;

    s = JS_GetOpaque2(ctx, this_val, JS_CLASS_SET);
    if (!s)
        return JS_EXCEPTION;
    setlike = argv[0];
    if (js_setlike_get_props(ctx, setlike, &size, &has, &keys) < 0)
        return JS_EXCEPTION;
    JS_FreeValue(ctx, has);
    iter = JS_UNDEFINED;
    next = JS_UNDEFINED;
    newset = js_map_constructor(ctx, JS_UNDEFINED, 0, NULL, MAGIC_SET);
    if (JS_IsException(newset))
        goto exception;
    t = JS_GetOpaque(newset, JS_CLASS_SET);
    // can't clone this_val using js_map_constructor(),
    // test262 mandates we don't call the .add method
    list_for_each(el, &s->records) {
        mr = list_entry(el, JSMapRecord, link);
        if (mr->empty)
            continue;
        mr = map_add_record(ctx, t, mr->key);
        if (!mr)
            goto exception;
        mr->value = JS_UNDEFINED;
    }
    iter = JS_Call(ctx, keys, setlike, 0, NULL);
    if (JS_IsException(iter))
        goto exception;
    next = JS_GetProperty(ctx, iter, JS_ATOM_next);
    if (JS_IsException(next))
        goto exception;
    for (;;) {
        item = JS_IteratorNext(ctx, iter, next, 0, NULL, &done);
        if (JS_IsException(item))
            goto exception;
        if (done) // item is JS_UNDEFINED
            break;
        // note the subtlety here: due to mutating iterators, it's
        // possible for keys to disappear during iteration; test262
        // still expects us to maintain insertion order though, so
        // we first check |this|, then |new|; |new| is a copy of |this|
        // - if item exists in |this|, delete (if it exists) from |new|
        // - if item misses in |this| and |new|, add to |new|
        // - if item exists in |new| but misses in |this|, *don't* add it,
        //   mutating iterator erased it
        item = map_normalize_key(ctx, item);
        present = (NULL != map_find_record(ctx, s, item));
        mr = map_find_record(ctx, t, item);
        if (present) {
            if (mr)
                map_delete_record(ctx->rt, t, mr);
            JS_FreeValue(ctx, item);
        } else if (mr) {
            JS_FreeValue(ctx, item);
        } else {
            mr = map_add_record(ctx, t, item);
            JS_FreeValue(ctx, item);
            if (!mr)
                goto exception;
            mr->value = JS_UNDEFINED;
        }
    }
    goto fini;
exception:
    JS_FreeValue(ctx, newset);
    newset = JS_EXCEPTION;
fini:
    JS_FreeValue(ctx, keys);
    JS_FreeValue(ctx, next);
    JS_FreeValue(ctx, iter);
    return newset;
}

static JSValue js_set_union(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv)
{
    JSValue has, item, iter, keys, newset, next, rv;
    JSValueConst setlike;
    struct list_head *el;
    JSMapState *s, *t;
    JSMapRecord *mr;
    uint64_t size;
    int done;

    iter = JS_UNDEFINED;
    s = JS_GetOpaque2(ctx, this_val, JS_CLASS_SET);
    if (!s)
        return JS_EXCEPTION;
    setlike = argv[0];
    if (js_setlike_get_props(ctx, setlike, &size, &has, &keys) < 0)
        return JS_EXCEPTION;
    JS_FreeValue(ctx, has);
    iter = JS_UNDEFINED;
    next = JS_UNDEFINED;
    newset = js_map_constructor(ctx, JS_UNDEFINED, 0, NULL, MAGIC_SET);
    if (JS_IsException(newset))
        goto exception;
    t = JS_GetOpaque(newset, JS_CLASS_SET);
    list_for_each(el, &s->records) {
        mr = list_entry(el, JSMapRecord, link);
        if (mr->empty)
            continue;
        mr = map_add_record(ctx, t, mr->key);
        if (!mr)
            goto exception;
        mr->value = JS_UNDEFINED;
    }
    iter = JS_Call(ctx, keys, setlike, 0, NULL);
    if (JS_IsException(iter))
        goto exception;
    next = JS_GetProperty(ctx, iter, JS_ATOM_next);
    if (JS_IsException(next))
        goto exception;
    for (;;) {
        item = JS_IteratorNext(ctx, iter, next, 0, NULL, &done);
        if (JS_IsException(item))
            goto exception;
        if (done) // item is JS_UNDEFINED
            break;
        rv = js_map_set(ctx, newset, 1, vc(&item), MAGIC_SET);
        JS_FreeValue(ctx, item);
        if (JS_IsException(rv))
            goto exception;
        JS_FreeValue(ctx, rv);
    }
    goto fini;
exception:
    JS_FreeValue(ctx, newset);
    newset = JS_EXCEPTION;
fini:
    JS_FreeValue(ctx, keys);
    JS_FreeValue(ctx, next);
    JS_FreeValue(ctx, iter);
    return newset;
}

static const JSCFunctionListEntry js_map_funcs[] = {
    JS_CFUNC_DEF("groupBy", 2, js_map_groupBy ),
    JS_CGETSET_DEF("[Symbol.species]", js_get_this, NULL ),
};

static const JSCFunctionListEntry js_set_funcs[] = {
    JS_CGETSET_DEF("[Symbol.species]", js_get_this, NULL ),
};

static const JSCFunctionListEntry js_map_proto_funcs[] = {
    JS_CFUNC_MAGIC_DEF("set", 2, js_map_set, 0 ),
    JS_CFUNC_MAGIC_DEF("get", 1, js_map_get, 0 ),
    JS_CFUNC_MAGIC_DEF("getOrInsert", 2, js_map_getOrInsert,
                       JS_CLASS_MAP<<1 | /*computed*/false ),
    JS_CFUNC_MAGIC_DEF("getOrInsertComputed", 2, js_map_getOrInsert,
                       JS_CLASS_MAP<<1 | /*computed*/true ),
    JS_CFUNC_MAGIC_DEF("has", 1, js_map_has, 0 ),
    JS_CFUNC_MAGIC_DEF("delete", 1, js_map_delete, 0 ),
    JS_CFUNC_MAGIC_DEF("clear", 0, js_map_clear, 0 ),
    JS_CGETSET_MAGIC_DEF("size", js_map_get_size, NULL, 0),
    JS_CFUNC_MAGIC_DEF("forEach", 1, js_map_forEach, 0 ),
    JS_CFUNC_MAGIC_DEF("values", 0, js_create_map_iterator, (JS_ITERATOR_KIND_VALUE << 2) | 0 ),
    JS_CFUNC_MAGIC_DEF("keys", 0, js_create_map_iterator, (JS_ITERATOR_KIND_KEY << 2) | 0 ),
    JS_CFUNC_MAGIC_DEF("entries", 0, js_create_map_iterator, (JS_ITERATOR_KIND_KEY_AND_VALUE << 2) | 0 ),
    JS_ALIAS_DEF("[Symbol.iterator]", "entries" ),
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "Map", JS_PROP_CONFIGURABLE ),
};

static const JSCFunctionListEntry js_map_iterator_proto_funcs[] = {
    JS_ITERATOR_NEXT_DEF("next", 0, js_map_iterator_next, 0 ),
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "Map Iterator", JS_PROP_CONFIGURABLE ),
};

static const JSCFunctionListEntry js_set_proto_funcs[] = {
    JS_CFUNC_MAGIC_DEF("add", 1, js_map_set, MAGIC_SET ),
    JS_CFUNC_MAGIC_DEF("has", 1, js_map_has, MAGIC_SET ),
    JS_CFUNC_MAGIC_DEF("delete", 1, js_map_delete, MAGIC_SET ),
    JS_CFUNC_MAGIC_DEF("clear", 0, js_map_clear, MAGIC_SET ),
    JS_CGETSET_MAGIC_DEF("size", js_map_get_size, NULL, MAGIC_SET ),
    JS_CFUNC_MAGIC_DEF("forEach", 1, js_map_forEach, MAGIC_SET ),
    JS_CFUNC_DEF("isDisjointFrom", 1, js_set_isDisjointFrom ),
    JS_CFUNC_DEF("isSubsetOf", 1, js_set_isSubsetOf ),
    JS_CFUNC_DEF("isSupersetOf", 1, js_set_isSupersetOf ),
    JS_CFUNC_DEF("intersection", 1, js_set_intersection ),
    JS_CFUNC_DEF("difference", 1, js_set_difference ),
    JS_CFUNC_DEF("symmetricDifference", 1, js_set_symmetricDifference ),
    JS_CFUNC_DEF("union", 1, js_set_union ),
    JS_CFUNC_MAGIC_DEF("values", 0, js_create_map_iterator, (JS_ITERATOR_KIND_KEY << 2) | MAGIC_SET ),
    JS_ALIAS_DEF("keys", "values" ),
    JS_ALIAS_DEF("[Symbol.iterator]", "values" ),
    JS_CFUNC_MAGIC_DEF("entries", 0, js_create_map_iterator, (JS_ITERATOR_KIND_KEY_AND_VALUE << 2) | MAGIC_SET ),
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "Set", JS_PROP_CONFIGURABLE ),
};

static const JSCFunctionListEntry js_set_iterator_proto_funcs[] = {
    JS_ITERATOR_NEXT_DEF("next", 0, js_map_iterator_next, MAGIC_SET ),
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "Set Iterator", JS_PROP_CONFIGURABLE ),
};

static const JSCFunctionListEntry js_weak_map_proto_funcs[] = {
    JS_CFUNC_MAGIC_DEF("set", 2, js_map_set, MAGIC_WEAK ),
    JS_CFUNC_MAGIC_DEF("get", 1, js_map_get, MAGIC_WEAK ),
    JS_CFUNC_MAGIC_DEF("getOrInsert", 2, js_map_getOrInsert,
                       JS_CLASS_WEAKMAP<<1 | /*computed*/false ),
    JS_CFUNC_MAGIC_DEF("getOrInsertComputed", 2, js_map_getOrInsert,
                       JS_CLASS_WEAKMAP<<1 | /*computed*/true ),
    JS_CFUNC_MAGIC_DEF("has", 1, js_map_has, MAGIC_WEAK ),
    JS_CFUNC_MAGIC_DEF("delete", 1, js_map_delete, MAGIC_WEAK ),
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "WeakMap", JS_PROP_CONFIGURABLE ),
};

static const JSCFunctionListEntry js_weak_set_proto_funcs[] = {
    JS_CFUNC_MAGIC_DEF("add", 1, js_map_set, MAGIC_SET | MAGIC_WEAK ),
    JS_CFUNC_MAGIC_DEF("has", 1, js_map_has, MAGIC_SET | MAGIC_WEAK ),
    JS_CFUNC_MAGIC_DEF("delete", 1, js_map_delete, MAGIC_SET | MAGIC_WEAK ),
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "WeakSet", JS_PROP_CONFIGURABLE ),
};

static const JSCFunctionListEntry * const js_map_proto_funcs_ptr[6] = {
    js_map_proto_funcs,
    js_set_proto_funcs,
    js_weak_map_proto_funcs,
    js_weak_set_proto_funcs,
    js_map_iterator_proto_funcs,
    js_set_iterator_proto_funcs,
};

static const uint8_t js_map_proto_funcs_count[6] = {
    countof(js_map_proto_funcs),
    countof(js_set_proto_funcs),
    countof(js_weak_map_proto_funcs),
    countof(js_weak_set_proto_funcs),
    countof(js_map_iterator_proto_funcs),
    countof(js_set_iterator_proto_funcs),
};

int JS_AddIntrinsicMapSet(JSContext *ctx)
{
    int i;
    JSValue obj1;
    char buf[ATOM_GET_STR_BUF_SIZE];
    /* Used to squelch a -Wcast-function-type warning. */
    JSCFunctionType ft = { .constructor_magic = js_map_constructor };

    for(i = 0; i < 4; i++) {
        const char *name = JS_AtomGetStr(ctx, buf, sizeof(buf),
                                         JS_ATOM_Map + i);
        int class_id = JS_CLASS_MAP + i;
        const JSCFunctionListEntry *ctor_funcs;
        int n_ctor_funcs;
        if (class_id == JS_CLASS_MAP) {
            ctor_funcs = js_map_funcs;
            n_ctor_funcs = countof(js_map_funcs);
        } else if (class_id == JS_CLASS_SET) {
            ctor_funcs = js_set_funcs;
            n_ctor_funcs = countof(js_set_funcs);
        } else {
            ctor_funcs = NULL;
            n_ctor_funcs = 0;
        }
        obj1 = JS_NewCConstructor(ctx, class_id, name,
                                  ft.generic, 0, JS_CFUNC_constructor_magic, i,
                                  JS_UNDEFINED,
                                  ctor_funcs, n_ctor_funcs,
                                  js_map_proto_funcs_ptr[i], js_map_proto_funcs_count[i],
                                  0);
        if (JS_IsException(obj1))
            return -1;
        JS_FreeValue(ctx, obj1);
    }

    for(i = 0; i < 2; i++) {
        ctx->class_proto[JS_CLASS_MAP_ITERATOR + i] =
            JS_NewObjectProtoList(ctx, ctx->class_proto[JS_CLASS_ITERATOR],
                                  js_map_proto_funcs_ptr[i + 4],
                                  js_map_proto_funcs_count[i + 4]);
        if (JS_IsException(ctx->class_proto[JS_CLASS_MAP_ITERATOR + i]))
            return -1;
    }
    return 0;
}

/* Generator */
static const JSCFunctionListEntry js_generator_function_proto_funcs[] = {
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "GeneratorFunction", JS_PROP_CONFIGURABLE),
};

static const JSCFunctionListEntry js_generator_proto_funcs[] = {
    JS_ITERATOR_NEXT_DEF("next", 1, js_generator_next, GEN_MAGIC_NEXT ),
    JS_ITERATOR_NEXT_DEF("return", 1, js_generator_next, GEN_MAGIC_RETURN ),
    JS_ITERATOR_NEXT_DEF("throw", 1, js_generator_next, GEN_MAGIC_THROW ),
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "Generator", JS_PROP_CONFIGURABLE),
};

/* Explicit resource management */

enum {
    JS_DISPOSE_HINT_SYNC,   /* use: Call(method, value) */
    JS_DISPOSE_HINT_ADOPT,  /* adopt: Call(method, undefined, [value]) */
    JS_DISPOSE_HINT_DEFER,  /* defer: Call(method, undefined) */
};

typedef struct JSDisposableResource {
    JSValue value;
    JSValue method; /* dispose method */
    uint8_t hint;
} JSDisposableResource;

typedef struct JSDisposableStack {
    bool disposed;
    int resource_count;
    int resource_capacity;
    JSDisposableResource *resources;
} JSDisposableStack;

static JSValue js_new_suppressed_error(JSContext *ctx, JSValueConst error,
                                       JSValueConst suppressed)
{
    JSValue obj;

    /* Construct via the intrinsic prototype rather than going through
       SuppressedError.prototype.constructor, which is user-writable. */
    obj = JS_NewObjectProtoClass(ctx,
                                 ctx->native_error_proto[JS_SUPPRESSED_ERROR],
                                 JS_CLASS_ERROR);
    if (JS_IsException(obj))
        return JS_EXCEPTION;
    JS_DefinePropertyValue(ctx, obj, JS_ATOM_error, js_dup(error),
                           JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
    JS_DefinePropertyValue(ctx, obj, JS_ATOM_suppressed, js_dup(suppressed),
                           JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
    build_backtrace(ctx, obj, JS_UNDEFINED, NULL, 0, 0,
                    JS_BACKTRACE_FLAG_SKIP_FIRST_LEVEL);
    return obj;
}

/* Perform DisposeResources. Returns 0 on success, -1 on exception.
   completion_error is the pending error (JS_UNDEFINED if none).
   It is consumed (freed) by this function. */
static int js_dispose_resources(JSContext *ctx, JSDisposableStack *ds,
                                JSValue completion_error)
{
    JSValue error = completion_error;
    bool has_error = !JS_IsUndefined(error);
    int i;

    ds->disposed = true;
    /* dispose in LIFO order */
    for (i = ds->resource_count - 1; i >= 0; i--) {
        JSDisposableResource *res = &ds->resources[i];
        JSValue ret;
        if (JS_IsUndefined(res->method)) {
            /* null/undefined resource, skip */
            JS_FreeValue(ctx, res->value);
            res->value = JS_UNDEFINED;
            continue;
        }
        switch (res->hint) {
        case JS_DISPOSE_HINT_ADOPT:
            ret = JS_Call(ctx, res->method, JS_UNDEFINED, 1, vc(&res->value));
            break;
        case JS_DISPOSE_HINT_DEFER:
            ret = JS_Call(ctx, res->method, JS_UNDEFINED, 0, NULL);
            break;
        default: /* JS_DISPOSE_HINT_SYNC */
            ret = JS_Call(ctx, res->method, res->value, 0, NULL);
            break;
        }
        JS_FreeValue(ctx, res->value);
        JS_FreeValue(ctx, res->method);
        res->value = JS_UNDEFINED;
        res->method = JS_UNDEFINED;
        if (JS_IsException(ret)) {
            JSValue new_error = JS_GetException(ctx);
            if (has_error) {
                JSValue suppressed = js_new_suppressed_error(ctx, new_error, error);
                JS_FreeValue(ctx, new_error);
                JS_FreeValue(ctx, error);
                if (JS_IsException(suppressed)) {
                    error = JS_GetException(ctx);
                } else {
                    error = suppressed;
                }
            } else {
                error = new_error;
                has_error = true;
            }
        } else {
            JS_FreeValue(ctx, ret);
        }
    }
    ds->resource_count = 0;
    if (has_error) {
        JS_Throw(ctx, error);
        return -1;
    }
    return 0;
}

static void js_disposable_stack_clear(JSRuntime *rt, JSDisposableStack *ds)
{
    int i;
    for (i = 0; i < ds->resource_count; i++) {
        JS_FreeValueRT(rt, ds->resources[i].value);
        JS_FreeValueRT(rt, ds->resources[i].method);
    }
    js_free_rt(rt, ds->resources);
}

static int js_disposable_stack_add(JSContext *ctx, JSDisposableStack *ds,
                                   JSValueConst value, JSValueConst method,
                                   int hint)
{
    if (ds->resource_count >= ds->resource_capacity) {
        int new_cap = max_int(ds->resource_capacity * 2, 4);
        JSDisposableResource *new_res;
        new_res = js_realloc(ctx, ds->resources,
                             new_cap * sizeof(JSDisposableResource));
        if (!new_res)
            return -1;
        ds->resources = new_res;
        ds->resource_capacity = new_cap;
    }
    ds->resources[ds->resource_count].value = js_dup(value);
    ds->resources[ds->resource_count].method = js_dup(method);
    ds->resources[ds->resource_count].hint = hint;
    ds->resource_count++;
    return 0;
}

static JSValue js_sync_dispose_wrapper(JSContext *ctx, JSValueConst this_val,
                                       int argc, JSValueConst *argv,
                                       int magic, JSValueConst *func_data)
{
    JSValueConst method = func_data[0];
    JSValue ret = JS_Call(ctx, method, this_val, 0, NULL);
    if (JS_IsException(ret))
        return JS_EXCEPTION;
    JS_FreeValue(ctx, ret);
    return JS_UNDEFINED;
}

static JSValue js_get_dispose_method(JSContext *ctx, JSValueConst value, int hint)
{
    JSValue method;

    if (hint == 1) {
        /* async: try Symbol.asyncDispose first */
        method = JS_GetProperty(ctx, value, JS_ATOM_Symbol_asyncDispose);
        if (JS_IsException(method))
            return JS_EXCEPTION;
        if (!JS_IsUndefined(method) && !JS_IsNull(method)) {
            if (!JS_IsFunction(ctx, method)) {
                JS_FreeValue(ctx, method);
                return JS_ThrowTypeError(ctx, "property is not a function");
            }
            return method;
        }
        JS_FreeValue(ctx, method);
        /* Fall back to Symbol.dispose, but wrap it so its return value is
           NOT awaited (per spec GetDisposeMethod). */
        method = JS_GetProperty(ctx, value, JS_ATOM_Symbol_dispose);
        if (JS_IsException(method))
            return JS_EXCEPTION;
        if (JS_IsUndefined(method) || JS_IsNull(method))
            return JS_ThrowTypeError(ctx, "property is not a function");
        if (!JS_IsFunction(ctx, method)) {
            JS_FreeValue(ctx, method);
            return JS_ThrowTypeError(ctx, "property is not a function");
        }

        {
            JSValue data[1], wrapped;
            data[0] = method;
            wrapped = JS_NewCFunctionData(ctx, js_sync_dispose_wrapper, 0, 0,
                                          1, vc(data));
            JS_FreeValue(ctx, method);
            return wrapped;
        }
    }

    /* sync dispose */
    method = JS_GetProperty(ctx, value, JS_ATOM_Symbol_dispose);
    if (JS_IsException(method))
        return JS_EXCEPTION;
    if (JS_IsUndefined(method) || JS_IsNull(method))
        return JS_ThrowTypeError(ctx, "property is not a function");
    if (!JS_IsFunction(ctx, method)) {
        JS_FreeValue(ctx, method);
        return JS_ThrowTypeError(ctx, "property is not a function");
    }
    return method;
}

static JSValue js_disposable_stack_constructor(JSContext *ctx,
                                               JSValueConst new_target,
                                               int argc, JSValueConst *argv,
                                               int class_id)
{
    JSDisposableStack *s;
    JSValue obj;

    if (JS_IsUndefined(new_target))
        return JS_ThrowTypeError(ctx, "Constructor requires 'new'");
    obj = js_create_from_ctor(ctx, new_target, class_id);
    if (JS_IsException(obj))
        return JS_EXCEPTION;
    s = js_mallocz(ctx, sizeof(*s));
    if (!s) {
        JS_FreeValue(ctx, obj);
        return JS_EXCEPTION;
    }
    JS_SetOpaqueInternal(obj, s);
    return obj;
}

static void js_disposable_stack_finalizer(JSRuntime *rt, JSValueConst val)
{
    JSObject *p;
    JSDisposableStack *s;

    p = JS_VALUE_GET_OBJ(val);
    s = p->u.opaque;
    if (s) {
        js_disposable_stack_clear(rt, s);
        js_free_rt(rt, s);
    }
}

static void js_disposable_stack_mark(JSRuntime *rt, JSValueConst val,
                                     JS_MarkFunc *mark_func)
{
    JSObject *p;
    JSDisposableStack *s;
    int i;

    p = JS_VALUE_GET_OBJ(val);
    s = p->u.opaque;
    if (s) {
        for (i = 0; i < s->resource_count; i++) {
            JS_MarkValue(rt, s->resources[i].value, mark_func);
            JS_MarkValue(rt, s->resources[i].method, mark_func);
        }
    }
}

static JSDisposableStack *js_disposable_stack_get(JSContext *ctx,
                                                  JSValueConst this_val,
                                                  int class_id)
{
    JSDisposableStack *s;
    s = JS_GetOpaque2(ctx, this_val, class_id);
    if (!s)
        return NULL;
    if (s->disposed) {
        JS_ThrowReferenceError(ctx, "DisposableStack has been disposed");
        return NULL;
    }
    return s;
}

static JSValue js_disposable_stack_use(JSContext *ctx, JSValueConst this_val,
                                       int argc, JSValueConst *argv, int class_id)
{
    JSDisposableStack *s;
    JSValueConst value;
    JSValue method;
    int hint = (class_id == JS_CLASS_ASYNC_DISPOSABLE_STACK) ? 1 : 0;

    s = js_disposable_stack_get(ctx, this_val, class_id);
    if (!s)
        return JS_EXCEPTION;
    value = argv[0];
    if (JS_IsNull(value) || JS_IsUndefined(value)) {
        /* For async stacks, a null/undefined resource still needs a record
           so disposeAsync performs the required Await(undefined). */
        if (class_id == JS_CLASS_ASYNC_DISPOSABLE_STACK) {
            if (js_disposable_stack_add(ctx, s, JS_UNDEFINED, JS_UNDEFINED,
                                        JS_DISPOSE_HINT_SYNC) < 0)
                return JS_EXCEPTION;
        }
        return js_dup(value);
    }
    if (!JS_IsObject(value))
        return JS_ThrowTypeError(ctx, "not an object");
    method = js_get_dispose_method(ctx, value, hint);
    if (JS_IsException(method))
        return JS_EXCEPTION;
    if (js_disposable_stack_add(ctx, s, value, method, JS_DISPOSE_HINT_SYNC) < 0) {
        JS_FreeValue(ctx, method);
        return JS_EXCEPTION;
    }
    JS_FreeValue(ctx, method);
    return js_dup(value);
}

static JSValue js_disposable_stack_adopt(JSContext *ctx, JSValueConst this_val,
                                         int argc, JSValueConst *argv, int class_id)
{
    JSDisposableStack *s;
    JSValueConst value, on_dispose;

    s = js_disposable_stack_get(ctx, this_val, class_id);
    if (!s)
        return JS_EXCEPTION;
    value = argv[0];
    on_dispose = argv[1];
    if (!JS_IsFunction(ctx, on_dispose))
        return JS_ThrowTypeError(ctx, "not a function");
    if (js_disposable_stack_add(ctx, s, value, on_dispose, JS_DISPOSE_HINT_ADOPT) < 0)
        return JS_EXCEPTION;
    return js_dup(value);
}

static JSValue js_disposable_stack_defer(JSContext *ctx, JSValueConst this_val,
                                         int argc, JSValueConst *argv, int class_id)
{
    JSDisposableStack *s;
    JSValueConst on_dispose;

    s = js_disposable_stack_get(ctx, this_val, class_id);
    if (!s)
        return JS_EXCEPTION;
    on_dispose = argv[0];
    if (!JS_IsFunction(ctx, on_dispose))
        return JS_ThrowTypeError(ctx, "not a function");
    if (js_disposable_stack_add(ctx, s, JS_UNDEFINED, on_dispose, JS_DISPOSE_HINT_DEFER) < 0)
        return JS_EXCEPTION;
    return JS_UNDEFINED;
}

/* Simple .then handler that discards its argument and returns undefined;
   used to normalize the chain's resolved value after all disposals. */
static JSValue js_async_dispose_to_undef(JSContext *ctx, JSValueConst this_val,
                                         int argc, JSValueConst *argv,
                                         int magic, JSValueConst *func_data)
{
    return JS_UNDEFINED;
}

static JSValue js_async_dispose_rethrow(JSContext *ctx, JSValueConst this_val,
                                        int argc, JSValueConst *argv,
                                        int magic, JSValueConst *func_data)
{
    JSValue prev_err = js_dup(func_data[0]);
    if (magic == 0) {
        return JS_Throw(ctx, prev_err);
    } else {
        JSValue se = js_new_suppressed_error(ctx, argv[0], prev_err);
        JS_FreeValue(ctx, prev_err);
        if (JS_IsException(se))
            return JS_EXCEPTION;
        return JS_Throw(ctx, se);
    }
}

static JSValue js_async_dispose_step(JSContext *ctx, JSValueConst this_val,
                                     int argc, JSValueConst *argv,
                                     int magic, JSValueConst *func_data)
{
    JSValueConst value = func_data[0];
    JSValueConst method = func_data[1];
    int hint = JS_VALUE_GET_INT(func_data[2]);
    bool has_prev_err = (magic == 1);
    JSValue ret;

    if (JS_IsUndefined(method)) {
        /* null/undefined resource on async stack: Await(undefined) */
        if (has_prev_err)
            return JS_Throw(ctx, js_dup(argv[0]));
        return JS_UNDEFINED;
    }

    switch (hint) {
    case JS_DISPOSE_HINT_ADOPT:
        ret = JS_Call(ctx, method, JS_UNDEFINED, 1, &value);
        break;
    case JS_DISPOSE_HINT_DEFER:
        ret = JS_Call(ctx, method, JS_UNDEFINED, 0, NULL);
        break;
    default:
        ret = JS_Call(ctx, method, value, 0, NULL);
        break;
    }

    if (JS_IsException(ret)) {
        JSValue new_err = JS_GetException(ctx);
        if (has_prev_err) {
            JSValue se = js_new_suppressed_error(ctx, new_err, argv[0]);
            JS_FreeValue(ctx, new_err);
            if (JS_IsException(se))
                return JS_EXCEPTION;
            return JS_Throw(ctx, se);
        }
        return JS_Throw(ctx, new_err);
    }

    if (!has_prev_err) {
        /* Propagate method result; next .then awaits it */
        return ret;
    }

    /* Await ret, then rethrow the stored error (possibly wrapped) */
    {
        JSValueConst prev_err = argv[0];
        JSValue ret_promise, resolve_fn, reject_fn, then_args[2], result;
        ret_promise = js_promise_resolve(ctx, ctx->promise_ctor, 1, vc(&ret), 0);
        JS_FreeValue(ctx, ret);
        if (JS_IsException(ret_promise))
            return JS_EXCEPTION;
        resolve_fn = JS_NewCFunctionData(ctx, js_async_dispose_rethrow, 0, 0,
                                         1, &prev_err);
        reject_fn = JS_NewCFunctionData(ctx, js_async_dispose_rethrow, 1, 1,
                                        1, &prev_err);
        then_args[0] = resolve_fn;
        then_args[1] = reject_fn;
        result = JS_Invoke(ctx, ret_promise, JS_ATOM_then, 2, vc(then_args));
        JS_FreeValue(ctx, resolve_fn);
        JS_FreeValue(ctx, reject_fn);
        JS_FreeValue(ctx, ret_promise);
        return result;
    }
}

static JSValue js_disposable_stack_dispose(JSContext *ctx,
                                           JSValueConst this_val,
                                           int argc,
                                           JSValueConst *argv,
                                           int class_id)
{
    JSDisposableStack *s;

    s = JS_GetOpaque2(ctx, this_val, class_id);
    if (!s) {
        if (class_id == JS_CLASS_ASYNC_DISPOSABLE_STACK) {
            JSValue exc = JS_GetException(ctx);
            JSValue p = js_promise_resolve(ctx, ctx->promise_ctor, 1, vc(&exc),
                                           /*is_reject*/1);
            JS_FreeValue(ctx, exc);
            return p;
        }
        return JS_EXCEPTION;
    }
    if (s->disposed) {
        if (class_id == JS_CLASS_ASYNC_DISPOSABLE_STACK) {
            JSValue undef = JS_UNDEFINED;
            return js_promise_resolve(ctx, ctx->promise_ctor, 1, vc(&undef),
                                      /*is_reject*/0);
        }
        return JS_UNDEFINED;
    }
    if (class_id == JS_CLASS_ASYNC_DISPOSABLE_STACK) {
        /* Per spec DisposeResources: iterate resources in LIFO order and
           for each do Call + Await. The first Call happens synchronously
           inside disposeAsync(); subsequent Calls fire in microtasks via a
           Promise.then() chain so that each call sees the previous
           dispose's promise already settled. */
        int i, count = s->resource_count;
        JSValue chain, undef, ret;

        s->disposed = true;

        /* First (top-of-stack) resource: synchronous Call. */
        undef = JS_UNDEFINED;
        i = count - 1;
        if (i < 0) {
            chain = js_promise_resolve(ctx, ctx->promise_ctor, 1, vc(&undef),
                                       /*is_reject*/0);
            if (JS_IsException(chain))
                goto async_dispose_fail;
        } else {
            JSDisposableResource *res = &s->resources[i];
            if (JS_IsUndefined(res->method)) {
                /* null/undefined resource: Await(undefined) */
                chain = js_promise_resolve(ctx, ctx->promise_ctor, 1,
                                           vc(&undef), /*is_reject*/0);
            } else {
                switch (res->hint) {
                case JS_DISPOSE_HINT_ADOPT:
                    ret = JS_Call(ctx, res->method, JS_UNDEFINED, 1,
                                  vc(&res->value));
                    break;
                case JS_DISPOSE_HINT_DEFER:
                    ret = JS_Call(ctx, res->method, JS_UNDEFINED, 0, NULL);
                    break;
                default:
                    ret = JS_Call(ctx, res->method, res->value, 0, NULL);
                    break;
                }
                if (JS_IsException(ret)) {
                    JSValue err = JS_GetException(ctx);
                    chain = js_promise_resolve(ctx, ctx->promise_ctor, 1,
                                               vc(&err), /*is_reject*/1);
                    JS_FreeValue(ctx, err);
                } else {
                    chain = js_promise_resolve(ctx, ctx->promise_ctor, 1,
                                               vc(&ret), /*is_reject*/0);
                    JS_FreeValue(ctx, ret);
                }
            }
            JS_FreeValue(ctx, res->value);
            JS_FreeValue(ctx, res->method);
            res->value = JS_UNDEFINED;
            res->method = JS_UNDEFINED;
            if (JS_IsException(chain)) {
                i--;
                goto async_dispose_fail;
            }
            i--;
        }

        /* Remaining resources: chain lazy steps. */
        for (; i >= 0; i--) {
            JSDisposableResource *res = &s->resources[i];
            JSValueConst data[3];
            JSValue hint_val, resolve_fn, reject_fn, then_args[2], new_chain;

            hint_val = JS_NewInt32(ctx, res->hint);
            data[0] = res->value;
            data[1] = res->method;
            data[2] = hint_val;
            resolve_fn = JS_NewCFunctionData(ctx, js_async_dispose_step, 0, 0,
                                             3, data);
            reject_fn = JS_NewCFunctionData(ctx, js_async_dispose_step, 1, 1,
                                            3, data);
            JS_FreeValue(ctx, hint_val);
            JS_FreeValue(ctx, res->value);
            JS_FreeValue(ctx, res->method);
            res->value = JS_UNDEFINED;
            res->method = JS_UNDEFINED;
            if (JS_IsException(resolve_fn) || JS_IsException(reject_fn)) {
                JS_FreeValue(ctx, resolve_fn);
                JS_FreeValue(ctx, reject_fn);
                JS_FreeValue(ctx, chain);
                chain = JS_EXCEPTION;
                goto async_dispose_fail;
            }
            then_args[0] = resolve_fn;
            then_args[1] = reject_fn;
            new_chain = JS_Invoke(ctx, chain, JS_ATOM_then, 2, vc(then_args));
            JS_FreeValue(ctx, resolve_fn);
            JS_FreeValue(ctx, reject_fn);
            JS_FreeValue(ctx, chain);
            if (JS_IsException(new_chain)) {
                chain = JS_EXCEPTION;
                goto async_dispose_fail;
            }
            chain = new_chain;
        }
        s->resource_count = 0;

        if (count > 0) {
            JSValue undef_fn, then_args[1], new_chain;
            undef_fn = JS_NewCFunctionData(ctx, js_async_dispose_to_undef,
                                           0, 0, 0, NULL);
            if (JS_IsException(undef_fn)) {
                JS_FreeValue(ctx, chain);
                return JS_EXCEPTION;
            }
            then_args[0] = undef_fn;
            new_chain = JS_Invoke(ctx, chain, JS_ATOM_then, 1, vc(then_args));
            JS_FreeValue(ctx, undef_fn);
            JS_FreeValue(ctx, chain);
            return new_chain;
        }
        return chain;

    async_dispose_fail:
        for (; i >= 0; i--) {
            JSDisposableResource *res = &s->resources[i];
            JS_FreeValue(ctx, res->value);
            JS_FreeValue(ctx, res->method);
            res->value = JS_UNDEFINED;
            res->method = JS_UNDEFINED;
        }
        s->resource_count = 0;
        return JS_EXCEPTION;
    }
    if (js_dispose_resources(ctx, s, JS_UNDEFINED) < 0)
        return JS_EXCEPTION;
    return JS_UNDEFINED;
}

static JSValue js_disposable_stack_move(JSContext *ctx, JSValueConst this_val,
                                        int argc, JSValueConst *argv, int class_id)
{
    JSDisposableStack *s, *ns;
    JSValue new_obj;

    s = js_disposable_stack_get(ctx, this_val, class_id);
    if (!s)
        return JS_EXCEPTION;
    /* Use the intrinsic prototype directly so tampering with the global
       binding or subclassing cannot redirect move(). */
    new_obj = JS_NewObjectProtoClass(ctx, ctx->class_proto[class_id],
                                     class_id);
    if (JS_IsException(new_obj))
        return JS_EXCEPTION;
    ns = js_mallocz(ctx, sizeof(*ns));
    if (!ns) {
        JS_FreeValue(ctx, new_obj);
        return JS_EXCEPTION;
    }
    JS_SetOpaqueInternal(new_obj, ns);
    /* Transfer resources to new stack */
    ns->resources = s->resources;
    ns->resource_count = s->resource_count;
    ns->resource_capacity = s->resource_capacity;
    /* Reset original stack */
    s->resources = NULL;
    s->resource_count = 0;
    s->resource_capacity = 0;
    s->disposed = true;
    return new_obj;
}

static JSValue js_disposable_stack_get_disposed(JSContext *ctx,
                                                JSValueConst this_val, int class_id)
{
    JSDisposableStack *s;

    s = JS_GetOpaque2(ctx, this_val, class_id);
    if (!s)
        return JS_EXCEPTION;
    return js_bool(s->disposed);
}

static const JSCFunctionListEntry js_disposable_stack_proto_funcs[] = {
    JS_CFUNC_MAGIC_DEF("adopt", 2, js_disposable_stack_adopt, JS_CLASS_DISPOSABLE_STACK ),
    JS_CFUNC_MAGIC_DEF("defer", 1, js_disposable_stack_defer, JS_CLASS_DISPOSABLE_STACK ),
    JS_CFUNC_MAGIC_DEF("dispose", 0, js_disposable_stack_dispose, JS_CLASS_DISPOSABLE_STACK ),
    JS_CFUNC_MAGIC_DEF("move", 0, js_disposable_stack_move, JS_CLASS_DISPOSABLE_STACK ),
    JS_CFUNC_MAGIC_DEF("use", 1, js_disposable_stack_use, JS_CLASS_DISPOSABLE_STACK ),
    JS_CGETSET_MAGIC_DEF("disposed", js_disposable_stack_get_disposed, NULL, JS_CLASS_DISPOSABLE_STACK ),
    JS_ALIAS_DEF("[Symbol.dispose]", "dispose" ),
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "DisposableStack", JS_PROP_CONFIGURABLE ),
};

static const JSCFunctionListEntry js_async_disposable_stack_proto_funcs[] = {
    JS_CFUNC_MAGIC_DEF("adopt", 2, js_disposable_stack_adopt, JS_CLASS_ASYNC_DISPOSABLE_STACK ),
    JS_CFUNC_MAGIC_DEF("defer", 1, js_disposable_stack_defer, JS_CLASS_ASYNC_DISPOSABLE_STACK ),
    JS_CFUNC_MAGIC_DEF("disposeAsync", 0, js_disposable_stack_dispose, JS_CLASS_ASYNC_DISPOSABLE_STACK ),
    JS_CFUNC_MAGIC_DEF("move", 0, js_disposable_stack_move, JS_CLASS_ASYNC_DISPOSABLE_STACK ),
    JS_CFUNC_MAGIC_DEF("use", 1, js_disposable_stack_use, JS_CLASS_ASYNC_DISPOSABLE_STACK ),
    JS_CGETSET_MAGIC_DEF("disposed", js_disposable_stack_get_disposed, NULL, JS_CLASS_ASYNC_DISPOSABLE_STACK ),
    JS_ALIAS_DEF("[Symbol.asyncDispose]", "disposeAsync" ),
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "AsyncDisposableStack", JS_PROP_CONFIGURABLE),
};

/* Promise */

typedef struct JSPromiseData {
    JSPromiseStateEnum promise_state;
    /* 0=fulfill, 1=reject, list of JSPromiseReactionData.link */
    struct list_head promise_reactions[2];
    bool is_handled;
    JSValue promise_result;
} JSPromiseData;

typedef struct JSPromiseFunctionDataResolved {
    int ref_count;
    bool already_resolved;
} JSPromiseFunctionDataResolved;

typedef struct JSPromiseFunctionData {
    JSValue promise;
    JSPromiseFunctionDataResolved *presolved;
} JSPromiseFunctionData;

typedef struct JSPromiseReactionData {
    struct list_head link; /* not used in promise_reaction_job */
    JSValue resolving_funcs[2];
    JSValue handler;
} JSPromiseReactionData;

JSPromiseStateEnum JS_PromiseState(JSContext *ctx, JSValueConst promise)
{
    JSPromiseData *s = JS_GetOpaque(promise, JS_CLASS_PROMISE);
    if (!s)
        return JS_PROMISE_NOT_A_PROMISE;
    return s->promise_state;
}

JSValue JS_PromiseResult(JSContext *ctx, JSValueConst promise)
{
    JSPromiseData *s = JS_GetOpaque(promise, JS_CLASS_PROMISE);
    if (!s)
        return JS_UNDEFINED;
    return js_dup(s->promise_result);
}

// Notify the host tracker of an unreported rejection's state
static void call_promise_rejection_tracker(JSContext *ctx, JSValueConst promise,
                                         bool is_handled)
{
    JSPromiseData *s = JS_GetOpaque(promise, JS_CLASS_PROMISE);
    JSRuntime *rt = ctx->rt;
    if (s && s->promise_state == JS_PROMISE_REJECTED && !s->is_handled &&
        rt->host_promise_rejection_tracker) {
        rt->host_promise_rejection_tracker(ctx, promise, s->promise_result,
                                           is_handled, rt->host_promise_rejection_tracker_opaque);
    }
}

// Mark rejected promise as handled by the engine itself and let the host know that the promise is handled
static void js_promise_set_handled(JSContext *ctx, JSValueConst promise)
{
    JSPromiseData *s = JS_GetOpaque(promise, JS_CLASS_PROMISE);
    if (!s)
        return;
    call_promise_rejection_tracker(ctx, promise, true);
    s->is_handled = true;
}

bool JS_IsPromise(JSValueConst val)
{
    if (JS_VALUE_GET_TAG(val) != JS_TAG_OBJECT)
        return false;
    return JS_VALUE_GET_OBJ(val)->class_id == JS_CLASS_PROMISE;
}

void JS_PromiseMarkAsHandled(JSContext *ctx, JSValueConst promise)
{
    js_promise_set_handled(ctx, promise);
}

JSValue JS_NewSettledPromise(JSContext *ctx, bool is_reject, JSValueConst value)
{
    return js_promise_resolve(ctx, ctx->promise_ctor, 1, &value, is_reject);
}

static int js_create_resolving_functions(JSContext *ctx, JSValue *args,
                                         JSValueConst promise);

static void promise_reaction_data_free(JSRuntime *rt,
                                       JSPromiseReactionData *rd)
{
    JS_FreeValueRT(rt, rd->resolving_funcs[0]);
    JS_FreeValueRT(rt, rd->resolving_funcs[1]);
    JS_FreeValueRT(rt, rd->handler);
    js_free_rt(rt, rd);
}

#ifdef ENABLE_DUMPS // JS_DUMP_PROMISE
#define promise_trace(ctx, ...) \
   do { \
     if (check_dump_flag(ctx->rt, JS_DUMP_PROMISE)) \
       printf(__VA_ARGS__); \
   } while (0)
#else
#define promise_trace(...)
#endif

static JSValue promise_reaction_job(JSContext *ctx, int argc,
                                    JSValueConst *argv)
{
    JSValueConst handler, func;
    JSValue res, res2;
    JSValueConst arg;
    bool is_reject;

    assert(argc == 5);
    handler = argv[2];
    is_reject = JS_ToBool(ctx, argv[3]);
    arg = argv[4];

    promise_trace(ctx, "promise_reaction_job: is_reject=%d\n", is_reject);

    if (JS_IsUndefined(handler)) {
        if (is_reject) {
            res = JS_Throw(ctx, js_dup(arg));
        } else {
            res = js_dup(arg);
        }
    } else {
        res = JS_Call(ctx, handler, JS_UNDEFINED, 1, &arg);
    }
    is_reject = JS_IsException(res);
    if (is_reject) {
        if (unlikely(JS_IsUncatchableError(ctx->rt->current_exception)))
            return JS_EXCEPTION;
        res = JS_GetException(ctx);
    }
    func = argv[is_reject];
    /* as an extension, we support undefined as value to avoid
       creating a dummy promise in the 'await' implementation of async
       functions */
    if (!JS_IsUndefined(func)) {
        res2 = JS_Call(ctx, func, JS_UNDEFINED, 1, vc(&res));
    } else {
        res2 = JS_UNDEFINED;
    }
    JS_FreeValue(ctx, res);

    return res2;
}

void JS_SetPromiseHook(JSRuntime *rt, JSPromiseHook promise_hook, void *opaque)
{
    rt->promise_hook = promise_hook;
    rt->promise_hook_opaque = opaque;
}

void JS_SetHostPromiseRejectionTracker(JSRuntime *rt,
                                       JSHostPromiseRejectionTracker *cb,
                                       void *opaque)
{
    rt->host_promise_rejection_tracker = cb;
    rt->host_promise_rejection_tracker_opaque = opaque;
}

static void fulfill_or_reject_promise(JSContext *ctx, JSValueConst promise,
                                      JSValueConst value, bool is_reject)
{
    JSPromiseData *s = JS_GetOpaque(promise, JS_CLASS_PROMISE);
    struct list_head *el, *el1;
    JSPromiseReactionData *rd;
    JSValueConst args[5];

    if (!s || s->promise_state != JS_PROMISE_PENDING)
        return; /* should never happen */
    set_value(ctx, &s->promise_result, js_dup(value));
    s->promise_state = JS_PROMISE_FULFILLED + is_reject;

    promise_trace(ctx, "fulfill_or_reject_promise: is_reject=%d\n", is_reject);

    if (s->promise_state == JS_PROMISE_FULFILLED) {
        JSRuntime *rt = ctx->rt;
        if (rt->promise_hook) {
            rt->promise_hook(ctx, JS_PROMISE_HOOK_RESOLVE, promise,
                             JS_UNDEFINED, rt->promise_hook_opaque);
        }
    }

    call_promise_rejection_tracker(ctx, promise, false);

    list_for_each_safe(el, el1, &s->promise_reactions[is_reject]) {
        rd = list_entry(el, JSPromiseReactionData, link);
        args[0] = rd->resolving_funcs[0];
        args[1] = rd->resolving_funcs[1];
        args[2] = rd->handler;
        args[3] = js_bool(is_reject);
        args[4] = value;
        JS_EnqueueJob(ctx, promise_reaction_job, 5, args);
        list_del(&rd->link);
        promise_reaction_data_free(ctx->rt, rd);
    }

    list_for_each_safe(el, el1, &s->promise_reactions[1 - is_reject]) {
        rd = list_entry(el, JSPromiseReactionData, link);
        list_del(&rd->link);
        promise_reaction_data_free(ctx->rt, rd);
    }
}

static JSValue js_promise_resolve_thenable_job(JSContext *ctx,
                                               int argc, JSValueConst *argv)
{
    JSValueConst promise, thenable, then;
    JSValue args[2], res;
    JSRuntime *rt;

    promise_trace(ctx, "js_promise_resolve_thenable_job\n");

    assert(argc == 3);
    promise = argv[0];
    thenable = argv[1];
    then = argv[2];
    if (js_create_resolving_functions(ctx, args, promise) < 0)
        return JS_EXCEPTION;
    rt = ctx->rt;
    if (rt->promise_hook) {
        rt->promise_hook(ctx, JS_PROMISE_HOOK_BEFORE, promise, JS_UNDEFINED,
                         rt->promise_hook_opaque);
    }
    res = JS_Call(ctx, then, thenable, 2, vc(args));
    if (rt->promise_hook) {
        rt->promise_hook(ctx, JS_PROMISE_HOOK_AFTER, promise, JS_UNDEFINED,
                         rt->promise_hook_opaque);
    }
    if (JS_IsException(res)) {
        JSValue error = JS_GetException(ctx);
        res = JS_Call(ctx, args[1], JS_UNDEFINED, 1, vc(&error));
        JS_FreeValue(ctx, error);
    }
    JS_FreeValue(ctx, args[0]);
    JS_FreeValue(ctx, args[1]);
    return res;
}

static void js_promise_resolve_function_free_resolved(JSRuntime *rt,
                                                      JSPromiseFunctionDataResolved *sr)
{
    if (--sr->ref_count == 0) {
        js_free_rt(rt, sr);
    }
}

static int js_create_resolving_functions(JSContext *ctx,
                                         JSValue *resolving_funcs,
                                         JSValueConst promise)

{
    JSValue obj;
    JSPromiseFunctionData *s;
    JSPromiseFunctionDataResolved *sr;
    int i, ret;

    resolving_funcs[0] = JS_UNDEFINED;
    resolving_funcs[1] = JS_UNDEFINED;
    sr = js_malloc(ctx, sizeof(*sr));
    if (!sr)
        return -1;
    sr->ref_count = 1;
    sr->already_resolved = false; /* must be shared between the two functions */
    ret = 0;
    for(i = 0; i < 2; i++) {
        obj = JS_NewObjectProtoClass(ctx, ctx->function_proto,
                                     JS_CLASS_PROMISE_RESOLVE_FUNCTION + i);
        if (JS_IsException(obj))
            goto fail;
        s = js_malloc(ctx, sizeof(*s));
        if (!s) {
            JS_FreeValue(ctx, obj);
        fail:
            JS_FreeValue(ctx, resolving_funcs[0]);
            resolving_funcs[0] = JS_UNDEFINED;
            ret = -1;
            break;
        }
        sr->ref_count++;
        s->presolved = sr;
        s->promise = js_dup(promise);
        JS_SetOpaqueInternal(obj, s);
        js_function_set_properties(ctx, obj, JS_ATOM_empty_string, 1);
        resolving_funcs[i] = obj;
    }
    js_promise_resolve_function_free_resolved(ctx->rt, sr);
    return ret;
}

static void js_promise_resolve_function_finalizer(JSRuntime *rt,
                                                  JSValueConst val)
{
    JSPromiseFunctionData *s = JS_VALUE_GET_OBJ(val)->u.promise_function_data;
    if (s) {
        js_promise_resolve_function_free_resolved(rt, s->presolved);
        JS_FreeValueRT(rt, s->promise);
        js_free_rt(rt, s);
    }
}

static void js_promise_resolve_function_mark(JSRuntime *rt, JSValueConst val,
                                             JS_MarkFunc *mark_func)
{
    JSPromiseFunctionData *s = JS_VALUE_GET_OBJ(val)->u.promise_function_data;
    if (s) {
        JS_MarkValue(rt, s->promise, mark_func);
    }
}

static JSValue js_promise_resolve_function_call(JSContext *ctx,
                                                JSValueConst func_obj,
                                                JSValueConst this_val,
                                                int argc, JSValueConst *argv,
                                                int flags)
{
    JSObject *p = JS_VALUE_GET_OBJ(func_obj);
    JSPromiseFunctionData *s;
    JSValueConst args[3];
    JSValueConst resolution;
    JSValue then;
    bool is_reject;

    s = p->u.promise_function_data;
    if (!s || s->presolved->already_resolved)
        return JS_UNDEFINED;
    s->presolved->already_resolved = true;
    is_reject = p->class_id - JS_CLASS_PROMISE_RESOLVE_FUNCTION;
    if (argc > 0)
        resolution = argv[0];
    else
        resolution = JS_UNDEFINED;
#ifdef ENABLE_DUMPS // JS_DUMP_PROMISE
    if (check_dump_flag(ctx->rt, JS_DUMP_PROMISE)) {
        printf("js_promise_resolving_function_call: is_reject=%d resolution=", is_reject);
        JS_DumpValue(ctx->rt, resolution);
        printf("\n");
    }
#endif
    if (is_reject || !JS_IsObject(resolution)) {
        goto done;
    } else if (js_same_value(ctx, resolution, s->promise)) {
        JS_ThrowTypeError(ctx, "promise self resolution");
        goto fail_reject;
    }
    then = JS_GetProperty(ctx, resolution, JS_ATOM_then);
    if (JS_IsException(then)) {
        JSValue error;
    fail_reject:
        error = JS_GetException(ctx);
        fulfill_or_reject_promise(ctx, s->promise, error, true);
        JS_FreeValue(ctx, error);
    } else if (!JS_IsFunction(ctx, then)) {
        JS_FreeValue(ctx, then);
    done:
        fulfill_or_reject_promise(ctx, s->promise, resolution, is_reject);
    } else {
        args[0] = s->promise;
        args[1] = resolution;
        args[2] = then;
        JS_EnqueueJob(ctx, js_promise_resolve_thenable_job, 3, args);
        JS_FreeValue(ctx, then);
    }
    return JS_UNDEFINED;
}

static void js_promise_finalizer(JSRuntime *rt, JSValueConst val)
{
    JSPromiseData *s = JS_GetOpaque(val, JS_CLASS_PROMISE);
    struct list_head *el, *el1;
    int i;

    if (!s)
        return;
    for(i = 0; i < 2; i++) {
        list_for_each_safe(el, el1, &s->promise_reactions[i]) {
            JSPromiseReactionData *rd =
                list_entry(el, JSPromiseReactionData, link);
            promise_reaction_data_free(rt, rd);
        }
    }
    JS_FreeValueRT(rt, s->promise_result);
    js_free_rt(rt, s);
}

static void js_promise_mark(JSRuntime *rt, JSValueConst val,
                            JS_MarkFunc *mark_func)
{
    JSPromiseData *s = JS_GetOpaque(val, JS_CLASS_PROMISE);
    struct list_head *el;
    int i;

    if (!s)
        return;
    for(i = 0; i < 2; i++) {
        list_for_each(el, &s->promise_reactions[i]) {
            JSPromiseReactionData *rd =
                list_entry(el, JSPromiseReactionData, link);
            JS_MarkValue(rt, rd->resolving_funcs[0], mark_func);
            JS_MarkValue(rt, rd->resolving_funcs[1], mark_func);
            JS_MarkValue(rt, rd->handler, mark_func);
        }
    }
    JS_MarkValue(rt, s->promise_result, mark_func);
}

/* Create a new promise object with resolving functions. Returns the promise
   and sets resolving_funcs[0] (resolve) and resolving_funcs[1] (reject). */
static JSValue js_promise_new(JSContext *ctx, JSValueConst new_target,
                               JSValue *resolving_funcs)
{
    JSValue obj;
    JSPromiseData *s;
    JSRuntime *rt;

    obj = js_create_from_ctor(ctx, new_target, JS_CLASS_PROMISE);
    if (JS_IsException(obj))
        return JS_EXCEPTION;
    s = js_mallocz(ctx, sizeof(*s));
    if (!s) {
        JS_FreeValue(ctx, obj);
        return JS_EXCEPTION;
    }
    s->promise_state = JS_PROMISE_PENDING;
    s->is_handled = false;
    init_list_head(&s->promise_reactions[0]);
    init_list_head(&s->promise_reactions[1]);
    s->promise_result = JS_UNDEFINED;
    JS_SetOpaqueInternal(obj, s);
    if (js_create_resolving_functions(ctx, resolving_funcs, obj)) {
        JS_FreeValue(ctx, obj);
        return JS_EXCEPTION;
    }
    rt = ctx->rt;
    if (rt->promise_hook) {
        JSValueConst parent_promise = JS_UNDEFINED;
        if (rt->parent_promise)
            parent_promise = rt->parent_promise->value;
        rt->promise_hook(ctx, JS_PROMISE_HOOK_INIT, obj, parent_promise,
                         rt->promise_hook_opaque);
    }
    return obj;
}

static JSValue js_promise_constructor(JSContext *ctx, JSValueConst new_target,
                                      int argc, JSValueConst *argv)
{
    JSValueConst executor;
    JSValue obj;
    JSValue args[2], ret;

    executor = argv[0];
    if (check_function(ctx, executor))
        return JS_EXCEPTION;
    obj = js_promise_new(ctx, new_target, args);
    if (JS_IsException(obj))
        return JS_EXCEPTION;
    ret = JS_Call(ctx, executor, JS_UNDEFINED, 2, vc(args));
    if (JS_IsException(ret)) {
        JSValue ret2, error;
        error = JS_GetException(ctx);
        ret2 = JS_Call(ctx, args[1], JS_UNDEFINED, 1, vc(&error));
        JS_FreeValue(ctx, error);
        if (JS_IsException(ret2))
            goto fail;
        JS_FreeValue(ctx, ret2);
    }
    JS_FreeValue(ctx, ret);
    JS_FreeValue(ctx, args[0]);
    JS_FreeValue(ctx, args[1]);
    return obj;
 fail:
    JS_FreeValue(ctx, args[0]);
    JS_FreeValue(ctx, args[1]);
    JS_FreeValue(ctx, obj);
    return JS_EXCEPTION;
}

static JSValue js_promise_executor(JSContext *ctx,
                                   JSValueConst this_val,
                                   int argc, JSValueConst *argv,
                                   int magic, JSValueConst *func_data)
{
    int i;

    for(i = 0; i < 2; i++) {
        if (!JS_IsUndefined(func_data[i]))
            return JS_ThrowTypeError(ctx, "resolving function already set");
        func_data[i] = js_dup(argv[i]);
    }
    return JS_UNDEFINED;
}

static JSValue js_promise_executor_new(JSContext *ctx)
{
    JSValueConst func_data[2];

    func_data[0] = JS_UNDEFINED;
    func_data[1] = JS_UNDEFINED;
    return JS_NewCFunctionData(ctx, js_promise_executor, 2,
                               0, 2, func_data);
}

static JSValue js_new_promise_capability(JSContext *ctx,
                                         JSValue *resolving_funcs,
                                         JSValueConst ctor)
{
    JSValue executor, result_promise;
    JSCFunctionDataRecord *s;
    int i;

    if (JS_IsUndefined(ctor) || js_same_value(ctx, ctor, ctx->promise_ctor))
        return js_promise_new(ctx, JS_UNDEFINED, resolving_funcs);
    executor = js_promise_executor_new(ctx);
    if (JS_IsException(executor))
        return JS_EXCEPTION;
    result_promise = JS_CallConstructor(ctx, ctor, 1, vc(&executor));
    if (JS_IsException(result_promise))
        goto fail;
    s = JS_GetOpaque(executor, JS_CLASS_C_FUNCTION_DATA);
    for(i = 0; i < 2; i++) {
        if (check_function(ctx, s->data[i]))
            goto fail;
    }
    for(i = 0; i < 2; i++)
        resolving_funcs[i] = js_dup(s->data[i]);
    JS_FreeValue(ctx, executor);
    return result_promise;
 fail:
    JS_FreeValue(ctx, executor);
    JS_FreeValue(ctx, result_promise);
    return JS_EXCEPTION;
}

JSValue JS_NewPromiseCapability(JSContext *ctx, JSValue *resolving_funcs)
{
    return js_new_promise_capability(ctx, resolving_funcs, JS_UNDEFINED);
}

JSValue JS_PromiseThen(JSContext *ctx, JSValueConst promise,
                       JSValueConst on_fulfilled,
                       JSValueConst on_rejected)
{
    JSValue result_promise, resolving_funcs[2];
    JSValueConst handlers[2] = { on_fulfilled, on_rejected };
    JSRuntime *rt = ctx->rt;
    JSValueLink link;
    bool have_promise_hook;
    int i, ret;

    if (!JS_GetOpaque2(ctx, promise, JS_CLASS_PROMISE))
        return JS_EXCEPTION;

    /* Match the embedding API: create an intrinsic promise and do not consult
       Promise.prototype.then or Symbol.species. */
    have_promise_hook = (rt->promise_hook != NULL);
    if (have_promise_hook) {
        link = (JSValueLink){rt->parent_promise, promise};
        rt->parent_promise = &link;
    }
    result_promise = JS_NewPromiseCapability(ctx, resolving_funcs);
    if (have_promise_hook)
        rt->parent_promise = link.next;
    if (JS_IsException(result_promise))
        return result_promise;

    ret = perform_promise_then(ctx, promise, handlers, vc(resolving_funcs));
    for (i = 0; i < 2; i++)
        JS_FreeValue(ctx, resolving_funcs[i]);
    if (ret) {
        JS_FreeValue(ctx, result_promise);
        return JS_EXCEPTION;
    }
    return result_promise;
}

static JSValue js_promise_resolve(JSContext *ctx, JSValueConst this_val,
                                  int argc, JSValueConst *argv, int magic)
{
    JSValue result_promise, resolving_funcs[2], ret;
    bool is_reject = magic;

    if (!JS_IsObject(this_val))
        return JS_ThrowTypeErrorNotAnObject(ctx);
    if (!is_reject && JS_GetOpaque(argv[0], JS_CLASS_PROMISE)) {
        JSValue ctor;
        bool is_same;
        ctor = JS_GetProperty(ctx, argv[0], JS_ATOM_constructor);
        if (JS_IsException(ctor))
            return ctor;
        is_same = js_same_value(ctx, ctor, this_val);
        JS_FreeValue(ctx, ctor);
        if (is_same)
            return js_dup(argv[0]);
    }
    result_promise = js_new_promise_capability(ctx, resolving_funcs, this_val);
    if (JS_IsException(result_promise))
        return result_promise;
    ret = JS_Call(ctx, resolving_funcs[is_reject], JS_UNDEFINED, 1, argv);
    JS_FreeValue(ctx, resolving_funcs[0]);
    JS_FreeValue(ctx, resolving_funcs[1]);
    if (JS_IsException(ret)) {
        JS_FreeValue(ctx, result_promise);
        return ret;
    }
    JS_FreeValue(ctx, ret);
    return result_promise;
}

static JSValue js_promise_withResolvers(JSContext *ctx, JSValueConst this_val,
                                        int argc, JSValueConst *argv)
{
    static const JSAtom atoms[] = {JS_ATOM_promise, JS_ATOM_resolve, JS_ATOM_reject};
    JSValue values[3], obj, *pval;
    int i, ret;

    if (!JS_IsObject(this_val))
        return JS_ThrowTypeErrorNotAnObject(ctx);
    values[0] = js_new_promise_capability(ctx, &values[1], this_val);
    if (JS_IsException(values[0]))
        return JS_EXCEPTION;
    obj = JS_NewObject(ctx);
    if (JS_IsException(obj))
        goto exception;
    for (i = 0; i < (int)countof(values); i++) {
        pval = &values[i];
        ret = JS_DefinePropertyValue(ctx, obj, atoms[i], *pval, JS_PROP_C_W_E);
        *pval = JS_UNDEFINED; // consumed by JS_DefinePropertyValue
        if (ret < 0)
            goto exception;
    }
    return obj;
exception:
    for (i = 0; i < (int)countof(values); i++)
        JS_FreeValue(ctx, values[i]);
    JS_FreeValue(ctx, obj);
    return JS_EXCEPTION;
}

static JSValue js_promise_try(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv)
{
    JSValue result_promise, resolving_funcs[2], ret, ret2;
    bool is_reject = 0;

    if (!JS_IsObject(this_val))
        return JS_ThrowTypeErrorNotAnObject(ctx);
    result_promise = js_new_promise_capability(ctx, resolving_funcs, this_val);
    if (JS_IsException(result_promise))
        return result_promise;
    ret = JS_Call(ctx, argv[0], JS_UNDEFINED, argc - 1, argv + 1);
    if (JS_IsException(ret)) {
        is_reject = 1;
        ret = JS_GetException(ctx);
    }
    ret2 = JS_Call(ctx, resolving_funcs[is_reject], JS_UNDEFINED, 1, vc(&ret));
    JS_FreeValue(ctx, resolving_funcs[0]);
    JS_FreeValue(ctx, resolving_funcs[1]);
    JS_FreeValue(ctx, ret);
    if (JS_IsException(ret2)) {
        JS_FreeValue(ctx, result_promise);
        return ret2;
    }
    JS_FreeValue(ctx, ret2);
    return result_promise;
}

static __exception int remainingElementsCount_add(JSContext *ctx,
                                                  JSValueConst resolve_element_env,
                                                  int addend)
{
    JSValue val;
    int32_t remainingElementsCount;

    val = JS_GetPropertyUint32(ctx, resolve_element_env, 0);
    if (JS_IsException(val))
        return -1;
    if (JS_ToInt32Free(ctx, &remainingElementsCount, val))
        return -1;
    remainingElementsCount += addend;
    if (JS_SetPropertyUint32(ctx, resolve_element_env, 0,
                             js_int32(remainingElementsCount)) < 0)
        return -1;
    return (remainingElementsCount == 0);
}

#define PROMISE_MAGIC_all        0
#define PROMISE_MAGIC_allSettled 1
#define PROMISE_MAGIC_any        2

static JSValue js_promise_all_resolve_element(JSContext *ctx,
                                              JSValueConst this_val,
                                              int argc, JSValueConst *argv,
                                              int magic,
                                              JSValueConst *func_data)
{
    int resolve_type = magic & 3;
    int is_reject = magic & 4;
    bool alreadyCalled = JS_ToBool(ctx, func_data[0]);
    JSValueConst values = func_data[2];
    JSValueConst resolve = func_data[3];
    JSValueConst resolve_element_env = func_data[4];
    JSValue ret, obj;
    int is_zero;
    int32_t index;

    if (JS_ToInt32(ctx, &index, func_data[1]))
        return JS_EXCEPTION;
    if (alreadyCalled)
        return JS_UNDEFINED;
    func_data[0] = JS_TRUE;

    if (resolve_type == PROMISE_MAGIC_allSettled) {
        JSValue str;

        obj = JS_NewObject(ctx);
        if (JS_IsException(obj))
            return JS_EXCEPTION;
        str = js_new_string8(ctx, is_reject ? "rejected" : "fulfilled");
        if (JS_IsException(str))
            goto fail1;
        if (JS_DefinePropertyValue(ctx, obj, JS_ATOM_status,
                                   str,
                                   JS_PROP_C_W_E) < 0)
            goto fail1;
        if (JS_DefinePropertyValue(ctx, obj,
                                   is_reject ? JS_ATOM_reason : JS_ATOM_value,
                                   js_dup(argv[0]),
                                   JS_PROP_C_W_E) < 0) {
        fail1:
            JS_FreeValue(ctx, obj);
            return JS_EXCEPTION;
        }
    } else {
        obj = js_dup(argv[0]);
    }
    if (JS_DefinePropertyValueUint32(ctx, values, index,
                                     obj, JS_PROP_C_W_E) < 0)
        return JS_EXCEPTION;

    is_zero = remainingElementsCount_add(ctx, resolve_element_env, -1);
    if (is_zero < 0)
        return JS_EXCEPTION;
    if (is_zero) {
        if (resolve_type == PROMISE_MAGIC_any) {
            JSValue error;
            error = js_aggregate_error_constructor(ctx, values);
            if (JS_IsException(error))
                return JS_EXCEPTION;
            ret = JS_Call(ctx, resolve, JS_UNDEFINED, 1, vc(&error));
            JS_FreeValue(ctx, error);
        } else {
            ret = JS_Call(ctx, resolve, JS_UNDEFINED, 1, &values);
        }
        if (JS_IsException(ret))
            return ret;
        JS_FreeValue(ctx, ret);
    }
    return JS_UNDEFINED;
}

/* magic = 0: Promise.all 1: Promise.allSettled */
static JSValue js_promise_all(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv, int magic)
{
    JSValue result_promise, resolving_funcs[2], item, next_promise, ret;
    JSValue next_method = JS_UNDEFINED, values = JS_UNDEFINED;
    JSValue resolve_element_env = JS_UNDEFINED, resolve_element, reject_element;
    JSValue promise_resolve = JS_UNDEFINED, iter = JS_UNDEFINED;
    JSValueConst then_args[2], resolve_element_data[5];
    int done, index, is_zero, is_promise_any = (magic == PROMISE_MAGIC_any);

    if (!JS_IsObject(this_val))
        return JS_ThrowTypeErrorNotAnObject(ctx);
    result_promise = js_new_promise_capability(ctx, resolving_funcs, this_val);
    if (JS_IsException(result_promise))
        return result_promise;
    promise_resolve = JS_GetProperty(ctx, this_val, JS_ATOM_resolve);
    if (JS_IsException(promise_resolve) ||
        check_function(ctx, promise_resolve))
        goto fail_reject;
    iter = JS_GetIterator(ctx, argv[0], false);
    if (JS_IsException(iter)) {
        JSValue error;
    fail_reject:
        error = JS_GetException(ctx);
        ret = JS_Call(ctx, resolving_funcs[1], JS_UNDEFINED, 1, vc(&error));
        JS_FreeValue(ctx, error);
        if (JS_IsException(ret))
            goto fail;
        JS_FreeValue(ctx, ret);
    } else {
        next_method = JS_GetProperty(ctx, iter, JS_ATOM_next);
        if (JS_IsException(next_method))
            goto fail_reject;
        values = JS_NewArray(ctx);
        if (JS_IsException(values))
            goto fail_reject;
        resolve_element_env = JS_NewArray(ctx);
        if (JS_IsException(resolve_element_env))
            goto fail_reject;
        /* remainingElementsCount field */
        if (JS_DefinePropertyValueUint32(ctx, resolve_element_env, 0,
                                         js_int32(1),
                                         JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE | JS_PROP_WRITABLE) < 0)
            goto fail_reject;

        index = 0;
        for(;;) {
            /* XXX: conformance: should close the iterator if error on 'done'
               access, but not on 'value' access */
            item = JS_IteratorNext(ctx, iter, next_method, 0, NULL, &done);
            if (JS_IsException(item))
                goto fail_reject;
            if (done)
                break;
            next_promise = JS_Call(ctx, promise_resolve,
                                   this_val, 1, vc(&item));
            JS_FreeValue(ctx, item);
            if (JS_IsException(next_promise)) {
            fail_reject1:
                JS_IteratorClose(ctx, iter, true);
                goto fail_reject;
            }
            resolve_element_data[0] = JS_FALSE;
            resolve_element_data[1] = js_int32(index);
            resolve_element_data[2] = values;
            resolve_element_data[3] = resolving_funcs[is_promise_any];
            resolve_element_data[4] = resolve_element_env;
            resolve_element =
                JS_NewCFunctionData(ctx, js_promise_all_resolve_element, 1,
                                    magic, 5, resolve_element_data);
            if (JS_IsException(resolve_element)) {
                JS_FreeValue(ctx, next_promise);
                goto fail_reject1;
            }

            if (magic == PROMISE_MAGIC_allSettled) {
                reject_element =
                    JS_NewCFunctionData(ctx, js_promise_all_resolve_element, 1,
                                        magic | 4, 5, resolve_element_data);
                if (JS_IsException(reject_element)) {
                    JS_FreeValue(ctx, next_promise);
                    goto fail_reject1;
                }
            } else if (magic == PROMISE_MAGIC_any) {
                if (JS_DefinePropertyValueUint32(ctx, values, index,
                                                 JS_UNDEFINED, JS_PROP_C_W_E) < 0)
                    goto fail_reject1;
                reject_element = resolve_element;
                resolve_element = js_dup(resolving_funcs[0]);
            } else {
                reject_element = js_dup(resolving_funcs[1]);
            }

            if (remainingElementsCount_add(ctx, resolve_element_env, 1) < 0) {
                JS_FreeValue(ctx, next_promise);
                JS_FreeValue(ctx, resolve_element);
                JS_FreeValue(ctx, reject_element);
                goto fail_reject1;
            }

            then_args[0] = resolve_element;
            then_args[1] = reject_element;
            ret = JS_InvokeFree(ctx, next_promise, JS_ATOM_then, 2, then_args);
            JS_FreeValue(ctx, resolve_element);
            JS_FreeValue(ctx, reject_element);
            if (check_exception_free(ctx, ret))
                goto fail_reject1;
            index++;
        }

        is_zero = remainingElementsCount_add(ctx, resolve_element_env, -1);
        if (is_zero < 0)
            goto fail_reject;
        if (is_zero) {
            if (magic == PROMISE_MAGIC_any) {
                JSValue error;
                error = js_aggregate_error_constructor(ctx, values);
                if (JS_IsException(error))
                    goto fail_reject;
                JS_FreeValue(ctx, values);
                values = error;
            }
            ret = JS_Call(ctx, resolving_funcs[is_promise_any], JS_UNDEFINED,
                          1, vc(&values));
            if (check_exception_free(ctx, ret))
                goto fail_reject;
        }
    }
 done:
    JS_FreeValue(ctx, promise_resolve);
    JS_FreeValue(ctx, resolve_element_env);
    JS_FreeValue(ctx, values);
    JS_FreeValue(ctx, next_method);
    JS_FreeValue(ctx, iter);
    JS_FreeValue(ctx, resolving_funcs[0]);
    JS_FreeValue(ctx, resolving_funcs[1]);
    return result_promise;
 fail:
    JS_FreeValue(ctx, result_promise);
    result_promise = JS_EXCEPTION;
    goto done;
}

static JSValue js_promise_race(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv)
{
    JSValue result_promise, resolving_funcs[2], item, next_promise, ret;
    JSValue next_method = JS_UNDEFINED, iter = JS_UNDEFINED;
    JSValue promise_resolve = JS_UNDEFINED;
    int done;

    if (!JS_IsObject(this_val))
        return JS_ThrowTypeErrorNotAnObject(ctx);
    result_promise = js_new_promise_capability(ctx, resolving_funcs, this_val);
    if (JS_IsException(result_promise))
        return result_promise;
    promise_resolve = JS_GetProperty(ctx, this_val, JS_ATOM_resolve);
    if (JS_IsException(promise_resolve) ||
        check_function(ctx, promise_resolve))
        goto fail_reject;
    iter = JS_GetIterator(ctx, argv[0], false);
    if (JS_IsException(iter)) {
        JSValue error;
    fail_reject:
        error = JS_GetException(ctx);
        ret = JS_Call(ctx, resolving_funcs[1], JS_UNDEFINED, 1, vc(&error));
        JS_FreeValue(ctx, error);
        if (JS_IsException(ret))
            goto fail;
        JS_FreeValue(ctx, ret);
    } else {
        next_method = JS_GetProperty(ctx, iter, JS_ATOM_next);
        if (JS_IsException(next_method))
            goto fail_reject;

        for(;;) {
            /* XXX: conformance: should close the iterator if error on 'done'
               access, but not on 'value' access */
            item = JS_IteratorNext(ctx, iter, next_method, 0, NULL, &done);
            if (JS_IsException(item))
                goto fail_reject;
            if (done)
                break;
            next_promise = JS_Call(ctx, promise_resolve,
                                   this_val, 1, vc(&item));
            JS_FreeValue(ctx, item);
            if (JS_IsException(next_promise)) {
            fail_reject1:
                JS_IteratorClose(ctx, iter, true);
                goto fail_reject;
            }
            ret = JS_InvokeFree(ctx, next_promise, JS_ATOM_then, 2,
                                vc(resolving_funcs));
            if (check_exception_free(ctx, ret))
                goto fail_reject1;
        }
    }
 done:
    JS_FreeValue(ctx, promise_resolve);
    JS_FreeValue(ctx, next_method);
    JS_FreeValue(ctx, iter);
    JS_FreeValue(ctx, resolving_funcs[0]);
    JS_FreeValue(ctx, resolving_funcs[1]);
    return result_promise;
 fail:
    //JS_FreeValue(ctx, next_method); // why not???
    JS_FreeValue(ctx, result_promise);
    result_promise = JS_EXCEPTION;
    goto done;
}

static __exception int perform_promise_then(JSContext *ctx,
                                            JSValueConst promise,
                                            JSValueConst *resolve_reject,
                                            JSValueConst *cap_resolving_funcs)
{
    JSPromiseData *s = JS_GetOpaque(promise, JS_CLASS_PROMISE);
    JSPromiseReactionData *rd_array[2], *rd;
    int i, j;

    rd_array[0] = NULL;
    rd_array[1] = NULL;
    for(i = 0; i < 2; i++) {
        JSValueConst handler;
        rd = js_mallocz(ctx, sizeof(*rd));
        if (!rd) {
            if (i == 1)
                promise_reaction_data_free(ctx->rt, rd_array[0]);
            return -1;
        }
        for(j = 0; j < 2; j++)
            rd->resolving_funcs[j] = js_dup(cap_resolving_funcs[j]);
        handler = resolve_reject[i];
        if (!JS_IsFunction(ctx, handler))
            handler = JS_UNDEFINED;
        rd->handler = js_dup(handler);
        rd_array[i] = rd;
    }

    if (s->promise_state == JS_PROMISE_PENDING) {
        for(i = 0; i < 2; i++)
            list_add_tail(&rd_array[i]->link, &s->promise_reactions[i]);
    } else {
        JSValueConst args[5];
        call_promise_rejection_tracker(ctx, promise, true);
        i = s->promise_state - JS_PROMISE_FULFILLED;
        rd = rd_array[i];
        args[0] = rd->resolving_funcs[0];
        args[1] = rd->resolving_funcs[1];
        args[2] = rd->handler;
        args[3] = js_bool(i);
        args[4] = s->promise_result;
        JS_EnqueueJob(ctx, promise_reaction_job, 5, args);
        for(i = 0; i < 2; i++)
            promise_reaction_data_free(ctx->rt, rd_array[i]);
    }
    s->is_handled = true;
    return 0;
}

static JSValue js_promise_then(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv)
{
    JSValue ctor, result_promise, resolving_funcs[2];
    bool have_promise_hook;
    JSValueLink link;
    JSPromiseData *s;
    JSRuntime *rt;
    int i, ret;

    s = JS_GetOpaque2(ctx, this_val, JS_CLASS_PROMISE);
    if (!s)
        return JS_EXCEPTION;

    ctor = JS_SpeciesConstructor(ctx, this_val, JS_UNDEFINED);
    if (JS_IsException(ctor))
        return ctor;
    rt = ctx->rt;
    // always restore, even if js_new_promise_capability callee removes hook
    have_promise_hook = (rt->promise_hook != NULL);
    if (have_promise_hook) {
        link = (JSValueLink){rt->parent_promise, this_val};
        rt->parent_promise = &link;
    }
    result_promise = js_new_promise_capability(ctx, resolving_funcs, ctor);
    if (have_promise_hook)
        rt->parent_promise = link.next;
    JS_FreeValue(ctx, ctor);
    if (JS_IsException(result_promise))
        return result_promise;
    ret = perform_promise_then(ctx, this_val, argv, vc(resolving_funcs));
    for(i = 0; i < 2; i++)
        JS_FreeValue(ctx, resolving_funcs[i]);
    if (ret) {
        JS_FreeValue(ctx, result_promise);
        return JS_EXCEPTION;
    }
    return result_promise;
}

static JSValue js_promise_catch(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv)
{
    JSValueConst args[2];
    args[0] = JS_UNDEFINED;
    args[1] = argv[0];
    return JS_Invoke(ctx, this_val, JS_ATOM_then, 2, args);
}

static JSValue js_promise_finally_value_thunk(JSContext *ctx, JSValueConst this_val,
                                              int argc, JSValueConst *argv,
                                              int magic, JSValueConst *func_data)
{
    return js_dup(func_data[0]);
}

static JSValue js_promise_finally_thrower(JSContext *ctx, JSValueConst this_val,
                                          int argc, JSValueConst *argv,
                                          int magic, JSValueConst *func_data)
{
    return JS_Throw(ctx, js_dup(func_data[0]));
}

static JSValue js_promise_then_finally_func(JSContext *ctx, JSValueConst this_val,
                                            int argc, JSValueConst *argv,
                                            int magic, JSValueConst *func_data)
{
    JSValueConst ctor = func_data[0];
    JSValueConst onFinally = func_data[1];
    JSValue res, promise, ret, then_func;

    res = JS_Call(ctx, onFinally, JS_UNDEFINED, 0, NULL);
    if (JS_IsException(res))
        return res;
    promise = js_promise_resolve(ctx, ctor, 1, vc(&res), 0);
    JS_FreeValue(ctx, res);
    if (JS_IsException(promise))
        return promise;
    if (magic == 0) {
        then_func = JS_NewCFunctionData(ctx, js_promise_finally_value_thunk, 0,
                                        0, 1, argv);
    } else {
        then_func = JS_NewCFunctionData(ctx, js_promise_finally_thrower, 0,
                                        0, 1, argv);
    }
    if (JS_IsException(then_func)) {
        JS_FreeValue(ctx, promise);
        return then_func;
    }
    ret = JS_InvokeFree(ctx, promise, JS_ATOM_then, 1, vc(&then_func));
    JS_FreeValue(ctx, then_func);
    return ret;
}

static JSValue js_promise_finally(JSContext *ctx, JSValueConst this_val,
                                  int argc, JSValueConst *argv)
{
    JSValueConst onFinally = argv[0];
    JSValue ctor, ret;
    JSValue then_funcs[2];
    JSValueConst func_data[2];
    int i;

    ctor = JS_SpeciesConstructor(ctx, this_val, JS_UNDEFINED);
    if (JS_IsException(ctor))
        return ctor;
    if (!JS_IsFunction(ctx, onFinally)) {
        then_funcs[0] = js_dup(onFinally);
        then_funcs[1] = js_dup(onFinally);
    } else {
        func_data[0] = ctor;
        func_data[1] = onFinally;
        for(i = 0; i < 2; i++) {
            then_funcs[i] = JS_NewCFunctionData(ctx, js_promise_then_finally_func, 1, i, 2, func_data);
            if (JS_IsException(then_funcs[i])) {
                if (i == 1)
                    JS_FreeValue(ctx, then_funcs[0]);
                JS_FreeValue(ctx, ctor);
                return JS_EXCEPTION;
            }
        }
    }
    JS_FreeValue(ctx, ctor);
    ret = JS_Invoke(ctx, this_val, JS_ATOM_then, 2, vc(then_funcs));
    JS_FreeValue(ctx, then_funcs[0]);
    JS_FreeValue(ctx, then_funcs[1]);
    return ret;
}

static const JSCFunctionListEntry js_promise_funcs[] = {
    JS_CFUNC_MAGIC_DEF("resolve", 1, js_promise_resolve, 0 ),
    JS_CFUNC_MAGIC_DEF("reject", 1, js_promise_resolve, 1 ),
    JS_CFUNC_MAGIC_DEF("all", 1, js_promise_all, PROMISE_MAGIC_all ),
    JS_CFUNC_MAGIC_DEF("allSettled", 1, js_promise_all, PROMISE_MAGIC_allSettled ),
    JS_CFUNC_MAGIC_DEF("any", 1, js_promise_all, PROMISE_MAGIC_any ),
    JS_CFUNC_DEF("try", 1, js_promise_try ),
    JS_CFUNC_DEF("race", 1, js_promise_race ),
    JS_CFUNC_DEF("withResolvers", 0, js_promise_withResolvers ),
    JS_CGETSET_DEF("[Symbol.species]", js_get_this, NULL),
};

static const JSCFunctionListEntry js_promise_proto_funcs[] = {
    JS_CFUNC_DEF("then", 2, js_promise_then ),
    JS_CFUNC_DEF("catch", 1, js_promise_catch ),
    JS_CFUNC_DEF("finally", 1, js_promise_finally ),
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "Promise", JS_PROP_CONFIGURABLE ),
};

/* AsyncFunction */
static const JSCFunctionListEntry js_async_function_proto_funcs[] = {
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "AsyncFunction", JS_PROP_CONFIGURABLE ),
};

static JSValue js_async_from_sync_iterator_unwrap(JSContext *ctx,
                                                  JSValueConst this_val,
                                                  int argc, JSValueConst *argv,
                                                  int magic, JSValueConst *func_data)
{
    return js_create_iterator_result(ctx, js_dup(argv[0]),
                                     JS_ToBool(ctx, func_data[0]));
}

static JSValue js_async_from_sync_iterator_unwrap_func_create(JSContext *ctx,
                                                              bool done)
{
    JSValueConst func_data[1];

    func_data[0] = js_bool(done);
    return JS_NewCFunctionData(ctx, js_async_from_sync_iterator_unwrap,
                               1, 0, 1, func_data);
}

/* AsyncIteratorPrototype */

static const JSCFunctionListEntry js_async_iterator_proto_funcs[] = {
    JS_CFUNC_DEF("[Symbol.asyncIterator]", 0, js_iterator_proto_iterator ),
    JS_CFUNC_DEF("[Symbol.asyncDispose]", 0, js_async_iterator_proto_dispose ),
};

/* AsyncFromSyncIteratorPrototype */

typedef struct JSAsyncFromSyncIteratorData {
    JSValue sync_iter;
    JSValue next_method;
} JSAsyncFromSyncIteratorData;

static void js_async_from_sync_iterator_finalizer(JSRuntime *rt,
                                                  JSValueConst val)
{
    JSAsyncFromSyncIteratorData *s =
        JS_GetOpaque(val, JS_CLASS_ASYNC_FROM_SYNC_ITERATOR);
    if (s) {
        JS_FreeValueRT(rt, s->sync_iter);
        JS_FreeValueRT(rt, s->next_method);
        js_free_rt(rt, s);
    }
}

static void js_async_from_sync_iterator_mark(JSRuntime *rt, JSValueConst val,
                                             JS_MarkFunc *mark_func)
{
    JSAsyncFromSyncIteratorData *s =
        JS_GetOpaque(val, JS_CLASS_ASYNC_FROM_SYNC_ITERATOR);
    if (s) {
        JS_MarkValue(rt, s->sync_iter, mark_func);
        JS_MarkValue(rt, s->next_method, mark_func);
    }
}

static JSValue JS_CreateAsyncFromSyncIterator(JSContext *ctx,
                                              JSValue sync_iter)
{
    JSValue async_iter, next_method;
    JSAsyncFromSyncIteratorData *s;

    next_method = JS_GetProperty(ctx, sync_iter, JS_ATOM_next);
    if (JS_IsException(next_method))
        return JS_EXCEPTION;
    async_iter = JS_NewObjectClass(ctx, JS_CLASS_ASYNC_FROM_SYNC_ITERATOR);
    if (JS_IsException(async_iter)) {
        JS_FreeValue(ctx, next_method);
        return async_iter;
    }
    s = js_mallocz(ctx, sizeof(*s));
    if (!s) {
        JS_FreeValue(ctx, async_iter);
        JS_FreeValue(ctx, next_method);
        return JS_EXCEPTION;
    }
    s->sync_iter = js_dup(sync_iter);
    s->next_method = next_method;
    JS_SetOpaqueInternal(async_iter, s);
    return async_iter;
}

static JSValue js_async_from_sync_iterator_next(JSContext *ctx, JSValueConst this_val,
                                                int argc, JSValueConst *argv,
                                                int magic)
{
    JSValue promise, resolving_funcs[2], value, err, method;
    JSAsyncFromSyncIteratorData *s;
    int done;
    int is_reject;

    promise = JS_NewPromiseCapability(ctx, resolving_funcs);
    if (JS_IsException(promise))
        return JS_EXCEPTION;
    s = JS_GetOpaque(this_val, JS_CLASS_ASYNC_FROM_SYNC_ITERATOR);
    if (!s) {
        JS_ThrowTypeError(ctx, "not an Async-from-Sync Iterator");
        goto reject;
    }

    if (magic == GEN_MAGIC_NEXT) {
        method = js_dup(s->next_method);
    } else {
        method = JS_GetProperty(ctx, s->sync_iter,
                                magic == GEN_MAGIC_RETURN ? JS_ATOM_return :
                                JS_ATOM_throw);
        if (JS_IsException(method))
            goto reject;
        if (JS_IsUndefined(method) || JS_IsNull(method)) {
            if (magic == GEN_MAGIC_RETURN) {
                err = js_create_iterator_result(ctx, js_dup(argv[0]), true);
                is_reject = 0;
            } else if (JS_IteratorClose(ctx, s->sync_iter, false)) {
                err = JS_GetException(ctx);
                is_reject = 1;
            } else {
                err = JS_MakeError2(ctx, JS_TYPE_ERROR, /*add_backtrace*/true,
                                    "throw is not a method");
                is_reject = 1;
            }
            goto done_resolve;
        }
    }
    value = JS_IteratorNext2(ctx, s->sync_iter, method,
                             argc >= 1 ? 1 : 0, argv, &done);
    JS_FreeValue(ctx, method);
    if (JS_IsException(value))
        goto reject;
    if (done == 2) {
        JSValue obj = value;
        value = JS_IteratorGetCompleteValue(ctx, obj, &done);
        JS_FreeValue(ctx, obj);
        if (JS_IsException(value))
            goto reject;
    }

    if (JS_IsException(value)) {
        JSValue res2;
    reject:
        err = JS_GetException(ctx);
        is_reject = 1;
    done_resolve:
        res2 = JS_Call(ctx, resolving_funcs[is_reject], JS_UNDEFINED,
                       1, vc(&err));
        JS_FreeValue(ctx, err);
        JS_FreeValue(ctx, res2);
        JS_FreeValue(ctx, resolving_funcs[0]);
        JS_FreeValue(ctx, resolving_funcs[1]);
        return promise;
    }
    {
        JSValue value_wrapper_promise, resolve_reject[2];
        int res;

        value_wrapper_promise = js_promise_resolve(ctx, ctx->promise_ctor,
                                                   1, vc(&value), 0);
        if (JS_IsException(value_wrapper_promise)) {
            JS_FreeValue(ctx, value);
            goto reject;
        }

        resolve_reject[0] =
            js_async_from_sync_iterator_unwrap_func_create(ctx, done);
        if (JS_IsException(resolve_reject[0])) {
            JS_FreeValue(ctx, value_wrapper_promise);
            goto fail;
        }
        JS_FreeValue(ctx, value);
        resolve_reject[1] = JS_UNDEFINED;

        res = perform_promise_then(ctx, value_wrapper_promise,
                                   vc(resolve_reject),
                                   vc(resolving_funcs));
        JS_FreeValue(ctx, resolve_reject[0]);
        JS_FreeValue(ctx, value_wrapper_promise);
        JS_FreeValue(ctx, resolving_funcs[0]);
        JS_FreeValue(ctx, resolving_funcs[1]);
        if (res) {
            JS_FreeValue(ctx, promise);
            return JS_EXCEPTION;
        }
    }
    return promise;
 fail:
    JS_FreeValue(ctx, value);
    JS_FreeValue(ctx, resolving_funcs[0]);
    JS_FreeValue(ctx, resolving_funcs[1]);
    JS_FreeValue(ctx, promise);
    return JS_EXCEPTION;
}

static const JSCFunctionListEntry js_async_from_sync_iterator_proto_funcs[] = {
    JS_CFUNC_MAGIC_DEF("next", 1, js_async_from_sync_iterator_next, GEN_MAGIC_NEXT ),
    JS_CFUNC_MAGIC_DEF("return", 1, js_async_from_sync_iterator_next, GEN_MAGIC_RETURN ),
    JS_CFUNC_MAGIC_DEF("throw", 1, js_async_from_sync_iterator_next, GEN_MAGIC_THROW ),
};

/* AsyncGeneratorFunction */

static const JSCFunctionListEntry js_async_generator_function_proto_funcs[] = {
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "AsyncGeneratorFunction", JS_PROP_CONFIGURABLE ),
};

/* AsyncGenerator prototype */

static const JSCFunctionListEntry js_async_generator_proto_funcs[] = {
    JS_CFUNC_MAGIC_DEF("next", 1, js_async_generator_next, GEN_MAGIC_NEXT ),
    JS_CFUNC_MAGIC_DEF("return", 1, js_async_generator_next, GEN_MAGIC_RETURN ),
    JS_CFUNC_MAGIC_DEF("throw", 1, js_async_generator_next, GEN_MAGIC_THROW ),
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "AsyncGenerator", JS_PROP_CONFIGURABLE ),
};

static JSClassShortDef const js_async_class_def[] = {
    { JS_ATOM_Promise, js_promise_finalizer, js_promise_mark },                      /* JS_CLASS_PROMISE */
    { JS_ATOM_PromiseResolveFunction, js_promise_resolve_function_finalizer, js_promise_resolve_function_mark }, /* JS_CLASS_PROMISE_RESOLVE_FUNCTION */
    { JS_ATOM_PromiseRejectFunction, js_promise_resolve_function_finalizer, js_promise_resolve_function_mark }, /* JS_CLASS_PROMISE_REJECT_FUNCTION */
    { JS_ATOM_AsyncFunction, js_bytecode_function_finalizer, js_bytecode_function_mark },  /* JS_CLASS_ASYNC_FUNCTION */
    { JS_ATOM_AsyncFunctionResolve, js_async_function_resolve_finalizer, js_async_function_resolve_mark }, /* JS_CLASS_ASYNC_FUNCTION_RESOLVE */
    { JS_ATOM_AsyncFunctionReject, js_async_function_resolve_finalizer, js_async_function_resolve_mark }, /* JS_CLASS_ASYNC_FUNCTION_REJECT */
    { JS_ATOM_empty_string, js_async_from_sync_iterator_finalizer, js_async_from_sync_iterator_mark }, /* JS_CLASS_ASYNC_FROM_SYNC_ITERATOR */
    { JS_ATOM_AsyncGeneratorFunction, js_bytecode_function_finalizer, js_bytecode_function_mark },  /* JS_CLASS_ASYNC_GENERATOR_FUNCTION */
    { JS_ATOM_AsyncGenerator, js_async_generator_finalizer, js_async_generator_mark },  /* JS_CLASS_ASYNC_GENERATOR */
    { JS_ATOM_AsyncDisposableStack, js_disposable_stack_finalizer, js_disposable_stack_mark }, /* JS_CLASS_ASYNC_DISPOSABLE_STACK */
};

int JS_AddIntrinsicPromise(JSContext *ctx)
{
    JSRuntime *rt = ctx->rt;
    JSValue obj1;
    JSCFunctionType ft;

    if (!JS_IsRegisteredClass(rt, JS_CLASS_PROMISE)) {
        if (init_class_range(rt, js_async_class_def, JS_CLASS_PROMISE,
                             countof(js_async_class_def)))
            return -1;
        rt->class_array[JS_CLASS_PROMISE_RESOLVE_FUNCTION].call = js_promise_resolve_function_call;
        rt->class_array[JS_CLASS_PROMISE_REJECT_FUNCTION].call = js_promise_resolve_function_call;
        rt->class_array[JS_CLASS_ASYNC_FUNCTION].call = js_async_function_call;
        rt->class_array[JS_CLASS_ASYNC_FUNCTION_RESOLVE].call = js_async_function_resolve_call;
        rt->class_array[JS_CLASS_ASYNC_FUNCTION_REJECT].call = js_async_function_resolve_call;
        rt->class_array[JS_CLASS_ASYNC_GENERATOR_FUNCTION].call = js_async_generator_function_call;
    }

    /* Promise */
    obj1 = JS_NewCConstructor(ctx, JS_CLASS_PROMISE, "Promise",
                              js_promise_constructor, 1, JS_CFUNC_constructor, 0,
                              JS_UNDEFINED,
                              js_promise_funcs, countof(js_promise_funcs),
                              js_promise_proto_funcs, countof(js_promise_proto_funcs),
                              0);
    if (JS_IsException(obj1))
        return -1;
    ctx->promise_ctor = obj1;

    /* AsyncFunction */
    ft.generic_magic = js_function_constructor;
    obj1 = JS_NewCConstructor(ctx, JS_CLASS_ASYNC_FUNCTION, "AsyncFunction",
                              ft.generic, 1, JS_CFUNC_constructor_or_func_magic, JS_FUNC_ASYNC,
                              ctx->function_ctor,
                              NULL, 0,
                              js_async_function_proto_funcs, countof(js_async_function_proto_funcs),
                              JS_NEW_CTOR_NO_GLOBAL | JS_NEW_CTOR_READONLY);
    if (JS_IsException(obj1))
        return -1;
    JS_FreeValue(ctx, obj1);

    /* AsyncIteratorPrototype */
    ctx->async_iterator_proto =
        JS_NewObjectProtoList(ctx, ctx->class_proto[JS_CLASS_OBJECT],
                              js_async_iterator_proto_funcs,
                              countof(js_async_iterator_proto_funcs));
    if (JS_IsException(ctx->async_iterator_proto))
        return -1;

    /* AsyncFromSyncIteratorPrototype */
    ctx->class_proto[JS_CLASS_ASYNC_FROM_SYNC_ITERATOR] =
        JS_NewObjectProtoList(ctx, ctx->async_iterator_proto,
                              js_async_from_sync_iterator_proto_funcs,
                              countof(js_async_from_sync_iterator_proto_funcs));
    if (JS_IsException(ctx->class_proto[JS_CLASS_ASYNC_FROM_SYNC_ITERATOR]))
        return -1;

    /* AsyncGeneratorPrototype */
    ctx->class_proto[JS_CLASS_ASYNC_GENERATOR] =
        JS_NewObjectProtoList(ctx, ctx->async_iterator_proto,
                              js_async_generator_proto_funcs,
                              countof(js_async_generator_proto_funcs));
    if (JS_IsException(ctx->class_proto[JS_CLASS_ASYNC_GENERATOR]))
        return -1;

    /* AsyncGeneratorFunction */
    ft.generic_magic = js_function_constructor;
    obj1 = JS_NewCConstructor(ctx, JS_CLASS_ASYNC_GENERATOR_FUNCTION, "AsyncGeneratorFunction",
                              ft.generic, 1, JS_CFUNC_constructor_or_func_magic, JS_FUNC_ASYNC_GENERATOR,
                              ctx->function_ctor,
                              NULL, 0,
                              js_async_generator_function_proto_funcs, countof(js_async_generator_function_proto_funcs),
                              JS_NEW_CTOR_NO_GLOBAL | JS_NEW_CTOR_READONLY);
    if (JS_IsException(obj1))
        return -1;
    JS_FreeValue(ctx, obj1);

    if (JS_SetConstructor2(ctx, ctx->class_proto[JS_CLASS_ASYNC_GENERATOR_FUNCTION],
                           ctx->class_proto[JS_CLASS_ASYNC_GENERATOR],
                           JS_PROP_CONFIGURABLE, JS_PROP_CONFIGURABLE))
        return -1;

    /* AsyncDisposableStack */
    ctx->class_proto[JS_CLASS_ASYNC_DISPOSABLE_STACK] = JS_NewObject(ctx);
    JS_SetPropertyFunctionList(ctx, ctx->class_proto[JS_CLASS_ASYNC_DISPOSABLE_STACK],
                               js_async_disposable_stack_proto_funcs,
                               countof(js_async_disposable_stack_proto_funcs));
    JS_NewGlobalCConstructorMagic(ctx, "AsyncDisposableStack",
                                  js_disposable_stack_constructor, 0,
                                  ctx->class_proto[JS_CLASS_ASYNC_DISPOSABLE_STACK],
                                  JS_CLASS_ASYNC_DISPOSABLE_STACK);
    return 0;
}

/* URI handling */

static int string_get_hex(JSString *p, int k, int n) {
    int c = 0, h;
    while (n-- > 0) {
        if ((h = from_hex(string_get(p, k++))) < 0)
            return -1;
        c = (c << 4) | h;
    }
    return c;
}

static int isURIReserved(int c) {
    return c < 0x100 && memchr(";/?:@&=+$,#", c, sizeof(";/?:@&=+$,#") - 1) != NULL;
}

static int JS_PRINTF_FORMAT_ATTR(2, 3) js_throw_URIError(JSContext *ctx, JS_PRINTF_FORMAT const char *fmt, ...)
{
    va_list ap;

    va_start(ap, fmt);
    JS_ThrowError(ctx, JS_URI_ERROR, fmt, ap);
    va_end(ap);
    return -1;
}

static int hex_decode(JSContext *ctx, JSString *p, int k) {
    int c;

    if (k >= p->len || string_get(p, k) != '%')
        return js_throw_URIError(ctx, "expecting %%");
    if (k + 2 >= p->len || (c = string_get_hex(p, k + 1, 2)) < 0)
        return js_throw_URIError(ctx, "expecting hex digit");

    return c;
}

static JSValue js_global_decodeURI(JSContext *ctx, JSValueConst this_val,
                                   int argc, JSValueConst *argv, int isComponent)
{
    JSValue str;
    StringBuffer b_s, *b = &b_s;
    JSString *p;
    int k, c, c1, n, c_min;

    str = JS_ToString(ctx, argv[0]);
    if (JS_IsException(str))
        return str;

    string_buffer_init(ctx, b, 0);

    p = JS_VALUE_GET_STRING(str);
    for (k = 0; k < p->len;) {
        c = string_get(p, k);
        if (c == '%') {
            c = hex_decode(ctx, p, k);
            if (c < 0)
                goto fail;
            k += 3;
            if (c < 0x80) {
                if (!isComponent && isURIReserved(c)) {
                    c = '%';
                    k -= 2;
                }
            } else {
                /* Decode URI-encoded UTF-8 sequence */
                if (c >= 0xc0 && c <= 0xdf) {
                    n = 1;
                    c_min = 0x80;
                    c &= 0x1f;
                } else if (c >= 0xe0 && c <= 0xef) {
                    n = 2;
                    c_min = 0x800;
                    c &= 0xf;
                } else if (c >= 0xf0 && c <= 0xf7) {
                    n = 3;
                    c_min = 0x10000;
                    c &= 0x7;
                } else {
                    n = 0;
                    c_min = 1;
                    c = 0;
                }
                while (n-- > 0) {
                    c1 = hex_decode(ctx, p, k);
                    if (c1 < 0)
                        goto fail;
                    k += 3;
                    if ((c1 & 0xc0) != 0x80) {
                        c = 0;
                        break;
                    }
                    c = (c << 6) | (c1 & 0x3f);
                }
                if (c < c_min || c > 0x10FFFF || is_surrogate(c)) {
                    js_throw_URIError(ctx, "malformed UTF-8");
                    goto fail;
                }
            }
        } else {
            k++;
        }
        string_buffer_putc(b, c);
    }
    JS_FreeValue(ctx, str);
    return string_buffer_end(b);

fail:
    JS_FreeValue(ctx, str);
    string_buffer_free(b);
    return JS_EXCEPTION;
}

static int isUnescaped(int c) {
    static char const unescaped_chars[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        "abcdefghijklmnopqrstuvwxyz"
        "0123456789"
        "@*_+-./";
    return c < 0x100 &&
        memchr(unescaped_chars, c, sizeof(unescaped_chars) - 1);
}

static int isURIUnescaped(int c, int isComponent) {
    return c < 0x100 &&
        ((c >= 0x61 && c <= 0x7a) ||
         (c >= 0x41 && c <= 0x5a) ||
         (c >= 0x30 && c <= 0x39) ||
         memchr("-_.!~*'()", c, sizeof("-_.!~*'()") - 1) != NULL ||
         (!isComponent && isURIReserved(c)));
}

static int encodeURI_hex(StringBuffer *b, int c) {
    uint8_t buf[6];
    int n = 0;
    const char *hex = "0123456789ABCDEF";

    buf[n++] = '%';
    if (c >= 256) {
        buf[n++] = 'u';
        buf[n++] = hex[(c >> 12) & 15];
        buf[n++] = hex[(c >>  8) & 15];
    }
    buf[n++] = hex[(c >> 4) & 15];
    buf[n++] = hex[(c >> 0) & 15];
    return string_buffer_write8(b, buf, n);
}

static JSValue js_global_encodeURI(JSContext *ctx, JSValueConst this_val,
                                   int argc, JSValueConst *argv,
                                   int isComponent)
{
    JSValue str;
    StringBuffer b_s, *b = &b_s;
    JSString *p;
    int k, c, c1;

    str = JS_ToString(ctx, argv[0]);
    if (JS_IsException(str))
        return str;

    p = JS_VALUE_GET_STRING(str);
    string_buffer_init(ctx, b, p->len);
    for (k = 0; k < p->len;) {
        c = string_get(p, k);
        k++;
        if (isURIUnescaped(c, isComponent)) {
            string_buffer_putc16(b, c);
        } else {
            if (is_lo_surrogate(c)) {
                js_throw_URIError(ctx, "invalid character");
                goto fail;
            } else if (is_hi_surrogate(c)) {
                if (k >= p->len) {
                    js_throw_URIError(ctx, "expecting surrogate pair");
                    goto fail;
                }
                c1 = string_get(p, k);
                k++;
                if (!is_lo_surrogate(c1)) {
                    js_throw_URIError(ctx, "expecting surrogate pair");
                    goto fail;
                }
                c = from_surrogate(c, c1);
            }
            if (c < 0x80) {
                encodeURI_hex(b, c);
            } else {
                /* XXX: use C UTF-8 conversion ? */
                if (c < 0x800) {
                    encodeURI_hex(b, (c >> 6) | 0xc0);
                } else {
                    if (c < 0x10000) {
                        encodeURI_hex(b, (c >> 12) | 0xe0);
                    } else {
                        encodeURI_hex(b, (c >> 18) | 0xf0);
                        encodeURI_hex(b, ((c >> 12) & 0x3f) | 0x80);
                    }
                    encodeURI_hex(b, ((c >> 6) & 0x3f) | 0x80);
                }
                encodeURI_hex(b, (c & 0x3f) | 0x80);
            }
        }
    }
    JS_FreeValue(ctx, str);
    return string_buffer_end(b);

fail:
    JS_FreeValue(ctx, str);
    string_buffer_free(b);
    return JS_EXCEPTION;
}

static JSValue js_global_escape(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv)
{
    JSValue str;
    StringBuffer b_s, *b = &b_s;
    JSString *p;
    int i, len, c;

    str = JS_ToString(ctx, argv[0]);
    if (JS_IsException(str))
        return str;

    p = JS_VALUE_GET_STRING(str);
    string_buffer_init(ctx, b, p->len);
    for (i = 0, len = p->len; i < len; i++) {
        c = string_get(p, i);
        if (isUnescaped(c)) {
            string_buffer_putc16(b, c);
        } else {
            encodeURI_hex(b, c);
        }
    }
    JS_FreeValue(ctx, str);
    return string_buffer_end(b);
}

static JSValue js_global_unescape(JSContext *ctx, JSValueConst this_val,
                                  int argc, JSValueConst *argv)
{
    JSValue str;
    StringBuffer b_s, *b = &b_s;
    JSString *p;
    int i, len, c, n;

    str = JS_ToString(ctx, argv[0]);
    if (JS_IsException(str))
        return str;

    string_buffer_init(ctx, b, 0);
    p = JS_VALUE_GET_STRING(str);
    for (i = 0, len = p->len; i < len; i++) {
        c = string_get(p, i);
        if (c == '%') {
            if (i + 6 <= len
            &&  string_get(p, i + 1) == 'u'
            &&  (n = string_get_hex(p, i + 2, 4)) >= 0) {
                c = n;
                i += 6 - 1;
            } else
            if (i + 3 <= len
            &&  (n = string_get_hex(p, i + 1, 2)) >= 0) {
                c = n;
                i += 3 - 1;
            }
        }
        string_buffer_putc16(b, c);
    }
    JS_FreeValue(ctx, str);
    return string_buffer_end(b);
}

/* global object */

static const JSCFunctionListEntry js_global_funcs[] = {
    JS_CFUNC_DEF("parseInt", 2, js_parseInt ),
    JS_CFUNC_DEF("parseFloat", 1, js_parseFloat ),
    JS_CFUNC_DEF("isNaN", 1, js_global_isNaN ),
    JS_CFUNC_DEF("isFinite", 1, js_global_isFinite ),
    JS_CFUNC_DEF("queueMicrotask", 1, js_global_queueMicrotask ),

    JS_CFUNC_MAGIC_DEF("decodeURI", 1, js_global_decodeURI, 0 ),
    JS_CFUNC_MAGIC_DEF("decodeURIComponent", 1, js_global_decodeURI, 1 ),
    JS_CFUNC_MAGIC_DEF("encodeURI", 1, js_global_encodeURI, 0 ),
    JS_CFUNC_MAGIC_DEF("encodeURIComponent", 1, js_global_encodeURI, 1 ),
    JS_CFUNC_DEF("escape", 1, js_global_escape ),
    JS_CFUNC_DEF("unescape", 1, js_global_unescape ),
    // workarounds for msvc & djgpp where NAN and INFINITY
    // are not compile-time expressions
    JS_PROP_U2D_DEF("Infinity", 0x7FF0ull<<48, 0 ),
    JS_PROP_U2D_DEF("NaN", 0x7FF8ull<<48, 0 ),
    JS_PROP_UNDEFINED_DEF("undefined", 0 ),
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "global", JS_PROP_CONFIGURABLE ),
    JS_CFUNC_DEF("eval", 1, js_global_eval ),
};

/* Date */

static int64_t math_mod(int64_t a, int64_t b) {
    /* return positive modulo */
    int64_t m = a % b;
    return m + (m < 0) * b;
}

static int64_t floor_div_int64(int64_t a, int64_t b) {
    /* integer division rounding toward -Infinity */
    int64_t m = a % b;
    return (a - (m + (m < 0) * b)) / b;
}

static JSValue js_Date_parse(JSContext *ctx, JSValueConst this_val,
                             int argc, JSValueConst *argv);

static __exception int JS_ThisTimeValue(JSContext *ctx, double *valp,
                                        JSValueConst this_val)
{
    if (JS_VALUE_GET_TAG(this_val) == JS_TAG_OBJECT) {
        JSObject *p = JS_VALUE_GET_OBJ(this_val);
        if (p->class_id == JS_CLASS_DATE && JS_IsNumber(p->u.object_data))
            return JS_ToFloat64(ctx, valp, p->u.object_data);
    }
    JS_ThrowTypeError(ctx, "not a Date object");
    return -1;
}

static JSValue JS_SetThisTimeValue(JSContext *ctx, JSValueConst this_val, double v)
{
    if (JS_VALUE_GET_TAG(this_val) == JS_TAG_OBJECT) {
        JSObject *p = JS_VALUE_GET_OBJ(this_val);
        if (p->class_id == JS_CLASS_DATE) {
            JS_FreeValue(ctx, p->u.object_data);
            p->u.object_data = js_float64(v);
            return js_dup(p->u.object_data);
        }
    }
    return JS_ThrowTypeError(ctx, "not a Date object");
}

static int64_t days_from_year(int64_t y) {
    return 365 * (y - 1970) + floor_div_int64(y - 1969, 4) -
        floor_div_int64(y - 1901, 100) + floor_div_int64(y - 1601, 400);
}

static int64_t days_in_year(int64_t y) {
    return 365 + !(y % 4) - !(y % 100) + !(y % 400);
}

/* return the year, update days */
static int64_t year_from_days(int64_t *days) {
    int64_t y, d1, nd, d = *days;
    y = floor_div_int64(d * 10000, 3652425) + 1970;
    /* the initial approximation is very good, so only a few
       iterations are necessary */
    for(;;) {
        d1 = d - days_from_year(y);
        if (d1 < 0) {
            y--;
            d1 += days_in_year(y);
        } else {
            nd = days_in_year(y);
            if (d1 < nd)
                break;
            d1 -= nd;
            y++;
        }
    }
    *days = d1;
    return y;
}

static int const month_days[] = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
static char const month_names[] = "JanFebMarAprMayJunJulAugSepOctNovDec";
static char const day_names[] = "SunMonTueWedThuFriSat";

static __exception int get_date_fields(JSContext *ctx, JSValueConst obj,
                                       double fields[minimum_length(9)],
                                       int is_local, int force)
{
    double dval;
    int64_t d, days, wd, y, i, md, h, m, s, ms, tz = 0;

    if (JS_ThisTimeValue(ctx, &dval, obj))
        return -1;

    if (isnan(dval)) {
        if (!force)
            return false; /* NaN */
        d = 0;        /* initialize all fields to 0 */
    } else {
        d = dval;     /* assuming -8.64e15 <= dval <= -8.64e15 */
        if (is_local) {
            tz = -getTimezoneOffset(d);
            d += tz * 60000;
        }
    }

    /* result is >= 0, we can use % */
    h = math_mod(d, 86400000);
    days = (d - h) / 86400000;
    ms = h % 1000;
    h = (h - ms) / 1000;
    s = h % 60;
    h = (h - s) / 60;
    m = h % 60;
    h = (h - m) / 60;
    wd = math_mod(days + 4, 7); /* week day */
    y = year_from_days(&days);

    for(i = 0; i < 11; i++) {
        md = month_days[i];
        if (i == 1)
            md += days_in_year(y) - 365;
        if (days < md)
            break;
        days -= md;
    }
    fields[0] = y;
    fields[1] = i;
    fields[2] = days + 1;
    fields[3] = h;
    fields[4] = m;
    fields[5] = s;
    fields[6] = ms;
    fields[7] = wd;
    fields[8] = tz;
    return true;
}

static double time_clip(double t) {
    if (t >= -8.64e15 && t <= 8.64e15)
        return trunc(t) + 0.0;  /* convert -0 to +0 */
    else
        return NAN;
}

/* The spec mandates the use of 'double' and it specifies the order
   of the operations */
static double set_date_fields(double fields[minimum_length(7)], int is_local) {
    double y, m, dt, ym, mn, day, h, s, milli, time, tv;
    int yi, mi, i;
    int64_t days;
    volatile double temp;  /* enforce evaluation order */
    double d = NAN;

    JS_X87_FPCW_SAVE_AND_ADJUST(fpcw);
    /* emulate 21.4.1.15 MakeDay ( year, month, date ) */
    y = fields[0];
    m = fields[1];
    dt = fields[2];
    ym = y + floor(m / 12);
    mn = fmod(m, 12);
    if (mn < 0)
        mn += 12;
    if (ym < -271821 || ym > 275760)
        goto out;

    yi = ym;
    mi = mn;
    days = days_from_year(yi);
    for(i = 0; i < mi; i++) {
        days += month_days[i];
        if (i == 1)
            days += days_in_year(yi) - 365;
    }
    day = days + dt - 1;

    /* emulate 21.4.1.14 MakeTime ( hour, min, sec, ms ) */
    h = fields[3];
    m = fields[4];
    s = fields[5];
    milli = fields[6];
    /* Use a volatile intermediary variable to ensure order of evaluation
     * as specified in ECMA. This fixes a test262 error on
     * test262/test/built-ins/Date/UTC/fp-evaluation-order.js.
     * Without the volatile qualifier, the compile can generate code
     * that performs the computation in a different order or with instructions
     * that produce a different result such as FMA (float multiply and add).
     */
    time = h * 3600000;
    time += (temp = m * 60000);
    time += (temp = s * 1000);
    time += milli;

    /* emulate 21.4.1.16 MakeDate ( day, time ) */
    tv = (temp = day * 86400000) + time;   /* prevent generation of FMA */
    if (!isfinite(tv))
        goto out;

    /* adjust for local time and clip */
    if (is_local) {
        int64_t ti = tv < INT64_MIN ? INT64_MIN : tv >= 0x1p63 ? INT64_MAX : (int64_t)tv;
        tv += getTimezoneOffset(ti) * 60000;
    }
    d = time_clip(tv);
out:
    JS_X87_FPCW_RESTORE(fpcw);
    return d;
}

static JSValue get_date_field(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv, int magic)
{
    // get_date_field(obj, n, is_local)
    double fields[9];
    int res, n, is_local;

    is_local = magic & 0x0F;
    n = (magic >> 4) & 0x0F;
    res = get_date_fields(ctx, this_val, fields, is_local, 0);
    if (res < 0)
        return JS_EXCEPTION;
    if (!res)
        return JS_NAN;

    if (magic & 0x100) {    // getYear
        fields[0] -= 1900;
    }
    return js_number(fields[n]);
}

static JSValue set_date_field(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv, int magic)
{
    // _field(obj, first_field, end_field, args, is_local)
    double fields[9];
    int res, first_field, end_field, is_local, i, n;
    double d, a;

    d = NAN;
    first_field = (magic >> 8) & 0x0F;
    end_field = (magic >> 4) & 0x0F;
    is_local = magic & 0x0F;

    res = get_date_fields(ctx, this_val, fields, is_local, first_field == 0);
    if (res < 0)
        return JS_EXCEPTION;

    // Argument coercion is observable and must be done unconditionally.
    n = min_int(argc, end_field - first_field);
    for(i = 0; i < n; i++) {
        if (JS_ToFloat64(ctx, &a, argv[i]))
            return JS_EXCEPTION;
        if (!isfinite(a))
            res = false;
        fields[first_field + i] = trunc(a);
    }

    if (!res)
        return JS_NAN;

    if (argc > 0)
        d = set_date_fields(fields, is_local);

    return JS_SetThisTimeValue(ctx, this_val, d);
}

/* fmt:
   0: toUTCString: "Tue, 02 Jan 2018 23:04:46 GMT"
   1: toString: "Wed Jan 03 2018 00:05:22 GMT+0100 (CET)"
   2: toISOString: "2018-01-02T23:02:56.927Z"
   3: toLocaleString: "1/2/2018, 11:40:40 PM"
   part: 1=date, 2=time 3=all
   XXX: should use a variant of strftime().
 */
static JSValue get_date_string(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv, int magic)
{
    // _string(obj, fmt, part)
    char buf[64];
    double fields[9];
    int res, fmt, part, pos;
    int y, mon, d, h, m, s, ms, wd, tz;

    fmt = (magic >> 4) & 0x0F;
    part = magic & 0x0F;

    res = get_date_fields(ctx, this_val, fields, fmt & 1, 0);
    if (res < 0)
        return JS_EXCEPTION;
    if (!res) {
        if (fmt == 2)
            return JS_ThrowRangeError(ctx, "Date value is NaN");
        else
            return js_new_string8(ctx, "Invalid Date");
    }

    y = fields[0];
    mon = fields[1];
    d = fields[2];
    h = fields[3];
    m = fields[4];
    s = fields[5];
    ms = fields[6];
    wd = fields[7];
    tz = fields[8];

    pos = 0;

    if (part & 1) { /* date part */
        switch(fmt) {
        case 0:
            pos += snprintf(buf + pos, sizeof(buf) - pos,
                            "%.3s, %02d %.3s %0*d ",
                            day_names + wd * 3, d,
                            month_names + mon * 3, 4 + (y < 0), y);
            break;
        case 1:
            pos += snprintf(buf + pos, sizeof(buf) - pos,
                            "%.3s %.3s %02d %0*d",
                            day_names + wd * 3,
                            month_names + mon * 3, d, 4 + (y < 0), y);
            if (part == 3) {
                buf[pos++] = ' ';
            }
            break;
        case 2:
            if (y >= 0 && y <= 9999) {
                pos += snprintf(buf + pos, sizeof(buf) - pos,
                                "%04d", y);
            } else {
                pos += snprintf(buf + pos, sizeof(buf) - pos,
                                "%+07d", y);
            }
            pos += snprintf(buf + pos, sizeof(buf) - pos,
                            "-%02d-%02dT", mon + 1, d);
            break;
        case 3:
            pos += snprintf(buf + pos, sizeof(buf) - pos,
                            "%02d/%02d/%0*d", mon + 1, d, 4 + (y < 0), y);
            if (part == 3) {
                buf[pos++] = ',';
                buf[pos++] = ' ';
            }
            break;
        }
    }
    if (part & 2) { /* time part */
        switch(fmt) {
        case 0:
            pos += snprintf(buf + pos, sizeof(buf) - pos,
                            "%02d:%02d:%02d GMT", h, m, s);
            break;
        case 1:
            pos += snprintf(buf + pos, sizeof(buf) - pos,
                            "%02d:%02d:%02d GMT", h, m, s);
            if (tz < 0) {
                buf[pos++] = '-';
                tz = -tz;
            } else {
                buf[pos++] = '+';
            }
            /* tz is >= 0, can use % */
            pos += snprintf(buf + pos, sizeof(buf) - pos,
                            "%02d%02d", tz / 60, tz % 60);
            /* XXX: tack the time zone code? */
            break;
        case 2:
            pos += snprintf(buf + pos, sizeof(buf) - pos,
                            "%02d:%02d:%02d.%03dZ", h, m, s, ms);
            break;
        case 3:
            pos += snprintf(buf + pos, sizeof(buf) - pos,
                            "%02d:%02d:%02d %cM", (h + 11) % 12 + 1, m, s,
                            (h < 12) ? 'A' : 'P');
            break;
        }
    }
    if (!pos) {
        // XXX: should throw exception?
        return js_empty_string(ctx->rt);
    }
    return js_new_string8_len(ctx, buf, pos);
}

/* OS dependent: return the UTC time in ms since 1970. */
static int64_t date_now(void) {
    return js__gettimeofday_us() / 1000;
}

static JSValue js_date_constructor(JSContext *ctx, JSValueConst new_target,
                                   int argc, JSValueConst *argv)
{
    // Date(y, mon, d, h, m, s, ms)
    JSValue rv;
    int i, n;
    double a, val;

    if (JS_IsUndefined(new_target)) {
        /* invoked as function */
        argc = 0;
    }
    n = argc;
    if (n == 0) {
        val = date_now();
    } else if (n == 1) {
        JSValue v, dv;
        if (JS_VALUE_GET_TAG(argv[0]) == JS_TAG_OBJECT) {
            JSObject *p = JS_VALUE_GET_OBJ(argv[0]);
            if (p->class_id == JS_CLASS_DATE && JS_IsNumber(p->u.object_data)) {
                if (JS_ToFloat64(ctx, &val, p->u.object_data))
                    return JS_EXCEPTION;
                val = time_clip(val);
                goto has_val;
            }
        }
        v = JS_ToPrimitive(ctx, argv[0], HINT_NONE);
        if (JS_IsString(v)) {
            dv = js_Date_parse(ctx, JS_UNDEFINED, 1, vc(&v));
            JS_FreeValue(ctx, v);
            if (JS_IsException(dv))
                return JS_EXCEPTION;
            if (JS_ToFloat64Free(ctx, &val, dv))
                return JS_EXCEPTION;
        } else {
            if (JS_ToFloat64Free(ctx, &val, v))
                return JS_EXCEPTION;
        }
        val = time_clip(val);
    } else {
        double fields[] = { 0, 0, 1, 0, 0, 0, 0 };
        if (n > 7)
            n = 7;
        for(i = 0; i < n; i++) {
            if (JS_ToFloat64(ctx, &a, argv[i]))
                return JS_EXCEPTION;
            if (!isfinite(a))
                break;
            fields[i] = trunc(a);
            if (i == 0 && fields[0] >= 0 && fields[0] < 100)
                fields[0] += 1900;
        }
        val = (i == n) ? set_date_fields(fields, 1) : NAN;
    }
has_val:
    rv = js_create_from_ctor(ctx, new_target, JS_CLASS_DATE);
    if (!JS_IsException(rv))
        JS_SetObjectData(ctx, rv, js_float64(val));
    if (!JS_IsException(rv) && JS_IsUndefined(new_target)) {
        /* invoked as a function, return (new Date()).toString(); */
        JSValue s;
        s = get_date_string(ctx, rv, 0, NULL, 0x13);
        JS_FreeValue(ctx, rv);
        rv = s;
    }
    return rv;
}

static JSValue js_Date_UTC(JSContext *ctx, JSValueConst this_val,
                           int argc, JSValueConst *argv)
{
    // UTC(y, mon, d, h, m, s, ms)
    double fields[] = { 0, 0, 1, 0, 0, 0, 0 };
    int i, n;
    double a;

    n = argc;
    if (n == 0)
        return JS_NAN;
    if (n > 7)
        n = 7;
    for(i = 0; i < n; i++) {
        if (JS_ToFloat64(ctx, &a, argv[i]))
            return JS_EXCEPTION;
        if (!isfinite(a))
            return JS_NAN;
        fields[i] = trunc(a);
        if (i == 0 && fields[0] >= 0 && fields[0] < 100)
            fields[0] += 1900;
    }
    return js_float64(set_date_fields(fields, 0));
}

/* Date string parsing */

static bool string_skip_char(const uint8_t *sp, int *pp, int c) {
    if (sp[*pp] == c) {
        *pp += 1;
        return true;
    } else {
        return false;
    }
}

/* skip spaces, update offset, return next char */
static int string_skip_spaces(const uint8_t *sp, int *pp) {
    int c;
    while ((c = sp[*pp]) == ' ')
        *pp += 1;
    return c;
}

/* skip dashes dots and commas */
static int string_skip_separators(const uint8_t *sp, int *pp) {
    int c;
    while ((c = sp[*pp]) == '-' || c == '/' || c == '.' || c == ',')
        *pp += 1;
    return c;
}

/* skip a word, stop on spaces, digits and separators, update offset */
static int string_skip_until(const uint8_t *sp, int *pp, const char *stoplist) {
    int c;
    while (!strchr(stoplist, c = sp[*pp]))
        *pp += 1;
    return c;
}

/* parse a numeric field (max_digits = 0 -> no maximum) */
static bool string_get_digits(const uint8_t *sp, int *pp, int *pval,
                              int min_digits, int max_digits)
{
    int v = 0;
    int c, p = *pp, p_start;

    p_start = p;
    while ((c = sp[p]) >= '0' && c <= '9') {
        /* arbitrary limit to 9 digits */
        if (v >= 100000000)
            return false;
        v = v * 10 + c - '0';
        p++;
        if (p - p_start == max_digits)
            break;
    }
    if (p - p_start < min_digits)
        return false;
    *pval = v;
    *pp = p;
    return true;
}

static bool string_get_milliseconds(const uint8_t *sp, int *pp, int *pval) {
    /* parse optional fractional part as milliseconds and truncate. */
    /* spec does not indicate which rounding should be used */
    int mul = 100, ms = 0, c, p_start, p = *pp;

    c = sp[p];
    if (c == '.' || c == ',') {
        p++;
        p_start = p;
        while ((c = sp[p]) >= '0' && c <= '9') {
            ms += (c - '0') * mul;
            mul /= 10;
            p++;
            if (p - p_start == 9)
                break;
        }
        if (p > p_start) {
            /* only consume the separator if digits are present */
            *pval = ms;
            *pp = p;
        }
    }
    return true;
}

static bool string_get_tzoffset(const uint8_t *sp, int *pp, int *tzp, bool strict) {
    int tz = 0, sgn, hh, mm, p = *pp;

    sgn = sp[p++];
    if (sgn == '+' || sgn == '-') {
        int n = p;
        if (!string_get_digits(sp, &p, &hh, 1, 0))
            return false;
        n = p - n;
        if (strict && n != 2 && n != 4)
            return false;
        while (n > 4) {
            n -= 2;
            hh /= 100;
        }
        if (n > 2) {
            mm = hh % 100;
            hh = hh / 100;
        } else {
            mm = 0;
            if (string_skip_char(sp, &p, ':')  /* optional separator */
            &&  !string_get_digits(sp, &p, &mm, 2, 2))
                return false;
        }
        if (hh > 23 || mm > 59)
            return false;
        tz = hh * 60 + mm;
        if (sgn != '+')
            tz = -tz;
    } else
    if (sgn != 'Z') {
        return false;
    }
    *pp = p;
    *tzp = tz;
    return true;
}

static bool string_match(const uint8_t *sp, int *pp, const char *s) {
    int p = *pp;
    while (*s != '\0') {
        if (to_upper_ascii(sp[p]) != to_upper_ascii(*s++))
            return false;
        p++;
    }
    *pp = p;
    return true;
}

static int find_abbrev(const uint8_t *sp, int p, const char *list, int count) {
    int n, i;

    for (n = 0; n < count; n++) {
        for (i = 0;; i++) {
            if (to_upper_ascii(sp[p + i]) != to_upper_ascii(list[n * 3 + i]))
                break;
            if (i == 2)
                return n;
        }
    }
    return -1;
}

static bool string_get_month(const uint8_t *sp, int *pp, int *pval) {
    int n;

    n = find_abbrev(sp, *pp, month_names, 12);
    if (n < 0)
        return false;

    *pval = n + 1;
    *pp += 3;
    return true;
}

/* parse toISOString format */
static bool js_date_parse_isostring(const uint8_t *sp, int fields[9], bool *is_local) {
    int sgn, i, p = 0;

    /* initialize fields to the beginning of the Epoch */
    for (i = 0; i < 9; i++) {
        fields[i] = (i == 2);
    }
    *is_local = false;

    /* year is either yyyy digits or [+-]yyyyyy */
    sgn = sp[p];
    if (sgn == '-' || sgn == '+') {
        p++;
        if (!string_get_digits(sp, &p, &fields[0], 6, 6))
            return false;
        if (sgn == '-') {
            if (fields[0] == 0)
                return false; // reject -000000
            fields[0] = -fields[0];
        }
    } else {
        if (!string_get_digits(sp, &p, &fields[0], 4, 4))
            return false;
    }
    if (string_skip_char(sp, &p, '-')) {
        if (!string_get_digits(sp, &p, &fields[1], 2, 2))  /* month */
            return false;
        if (fields[1] < 1)
            return false;
        fields[1] -= 1;
        if (string_skip_char(sp, &p, '-')) {
            if (!string_get_digits(sp, &p, &fields[2], 2, 2))  /* day */
                return false;
            if (fields[2] < 1)
                return false;
        }
    }
    if (string_skip_char(sp, &p, 'T')) {
        *is_local = true;
        if (!string_get_digits(sp, &p, &fields[3], 2, 2)  /* hour */
        ||  !string_skip_char(sp, &p, ':')
        ||  !string_get_digits(sp, &p, &fields[4], 2, 2)) {  /* minute */
            fields[3] = 100;  // reject unconditionally
            return true;
        }
        if (string_skip_char(sp, &p, ':')) {
            if (!string_get_digits(sp, &p, &fields[5], 2, 2))  /* second */
                return false;
            string_get_milliseconds(sp, &p, &fields[6]);
        }
    }
    /* parse the time zone offset if present: [+-]HH:mm or [+-]HHmm */
    if (sp[p]) {
        *is_local = false;
        if (!string_get_tzoffset(sp, &p, &fields[8], true))
            return false;
    }
    /* error if extraneous characters */
    return sp[p] == '\0';
}

static struct {
    char name[6];
    int16_t offset;
} const js_tzabbr[] = {
    { "GMT",   0 },         // Greenwich Mean Time
    { "UTC",   0 },         // Coordinated Universal Time
    { "UT",    0 },         // Universal Time
    { "Z",     0 },         // Zulu Time
    { "EDT",  -4 * 60 },    // Eastern Daylight Time
    { "EST",  -5 * 60 },    // Eastern Standard Time
    { "CDT",  -5 * 60 },    // Central Daylight Time
    { "CST",  -6 * 60 },    // Central Standard Time
    { "MDT",  -6 * 60 },    // Mountain Daylight Time
    { "MST",  -7 * 60 },    // Mountain Standard Time
    { "PDT",  -7 * 60 },    // Pacific Daylight Time
    { "PST",  -8 * 60 },    // Pacific Standard Time
    { "WET",  +0 * 60 },    // Western European Time
    { "WEST", +1 * 60 },    // Western European Summer Time
    { "CET",  +1 * 60 },    // Central European Time
    { "CEST", +2 * 60 },    // Central European Summer Time
    { "EET",  +2 * 60 },    // Eastern European Time
    { "EEST", +3 * 60 },    // Eastern European Summer Time
};

static bool string_get_tzabbr(const uint8_t *sp, int *pp, int *offset) {
    size_t i;

    for (i = 0; i < countof(js_tzabbr); i++) {
        if (string_match(sp, pp, js_tzabbr[i].name)) {
            *offset = js_tzabbr[i].offset;
            return true;
        }
    }
    return false;
}

/* parse toString, toUTCString and other formats */
static bool js_date_parse_otherstring(const uint8_t *sp,
                                      int fields[minimum_length(9)],
                                      bool *is_local) {
    int c, i, val, p = 0, p_start;
    int num[3];
    bool has_year = false;
    bool has_mon = false;
    bool has_time = false;
    int num_index = 0;

    /* initialize fields to the beginning of 2001-01-01 */
    fields[0] = 2001;
    fields[1] = 1;
    fields[2] = 1;
    for (i = 3; i < 9; i++) {
        fields[i] = 0;
    }
    *is_local = true;

    while (string_skip_spaces(sp, &p)) {
        p_start = p;
        if ((c = sp[p]) == '+' || c == '-') {
            if (has_time && string_get_tzoffset(sp, &p, &fields[8], false)) {
                *is_local = false;
            } else {
                p++;
                if (string_get_digits(sp, &p, &val, 1, 0)) {
                    if (c == '-') {
                        if (val == 0)
                            return false;
                        val = -val;
                    }
                    fields[0] = val;
                    has_year = true;
                }
            }
        } else
        if (string_get_digits(sp, &p, &val, 1, 0)) {
            if (string_skip_char(sp, &p, ':')) {
                /* time part */
                fields[3] = val;
                if (!string_get_digits(sp, &p, &fields[4], 1, 2))
                    return false;
                if (string_skip_char(sp, &p, ':')) {
                    if (!string_get_digits(sp, &p, &fields[5], 1, 2))
                        return false;
                    string_get_milliseconds(sp, &p, &fields[6]);
                } else
                if (sp[p] != '\0' && sp[p] != ' ')
                    return false;
                has_time = true;
            } else {
                if (p - p_start > 2) {
                    fields[0] = val;
                    has_year = true;
                } else
                if (val < 1 || val > 31) {
                    fields[0] = val + (val < 100) * 1900 + (val < 50) * 100;
                    has_year = true;
                } else {
                    if (num_index == 3)
                        return false;
                    num[num_index++] = val;
                }
            }
        } else
        if (string_get_month(sp, &p, &fields[1])) {
            has_mon = true;
            string_skip_until(sp, &p, "0123456789 -/(");
        } else
        if (has_time && string_match(sp, &p, "PM")) {
            /* hours greater than 12 will be incremented and
               rejected by the range check in js_Date_parse */
            /* 00:00 PM will be silently converted as 12:00 */
            if (fields[3] != 12)
                fields[3] += 12;
            continue;
        } else
        if (has_time && string_match(sp, &p, "AM")) {
            /* 00:00 AM will be silently accepted */
            if (fields[3] > 12)
                return false;
            if (fields[3] == 12)
                fields[3] -= 12;
            continue;
        } else
        if (string_get_tzabbr(sp, &p, &fields[8])) {
            *is_local = false;
            continue;
        } else
        if (c == '(') {  /* skip parenthesized phrase */
            int level = 0;
            while ((c = sp[p]) != '\0') {
                p++;
                level += (c == '(');
                level -= (c == ')');
                if (!level)
                    break;
            }
            if (level > 0)
                return false;
        } else
        if (c == ')') {
            return false;
        } else {
            if (has_year + has_mon + has_time + num_index)
                return false;
            /* skip a word */
            string_skip_until(sp, &p, " -/(");
        }
        string_skip_separators(sp, &p);
    }
    if (num_index + has_year + has_mon > 3)
        return false;

    switch (num_index) {
    case 0:
        if (!has_year)
            return false;
        break;
    case 1:
        if (has_mon)
            fields[2] = num[0];
        else
            fields[1] = num[0];
        break;
    case 2:
        if (has_year) {
            fields[1] = num[0];
            fields[2] = num[1];
        } else
        if (has_mon) {
            fields[0] = num[1] + (num[1] < 100) * 1900 + (num[1] < 50) * 100;
            fields[2] = num[0];
        } else {
            fields[1] = num[0];
            fields[2] = num[1];
        }
        break;
    case 3:
        fields[0] = num[2] + (num[2] < 100) * 1900 + (num[2] < 50) * 100;
        fields[1] = num[0];
        fields[2] = num[1];
        break;
    default:
        return false;
    }
    if (fields[1] < 1 || fields[2] < 1)
        return false;
    fields[1] -= 1;
    return true;
}

static JSValue js_Date_parse(JSContext *ctx, JSValueConst this_val,
                             int argc, JSValueConst *argv)
{
    JSValue s, rv;
    int fields[9];
    double fields1[9];
    double d;
    int i, c;
    JSString *sp;
    uint8_t buf[128];
    bool is_local;

    rv = JS_NAN;

    s = JS_ToString(ctx, argv[0]);
    if (JS_IsException(s))
        return JS_EXCEPTION;

    sp = JS_VALUE_GET_STRING(s);
    /* convert the string as a byte array */
    for (i = 0; i < sp->len && i < (int)countof(buf) - 1; i++) {
        c = string_get(sp, i);
        if (c > 255)
            c = (c == 0x2212) ? '-' : 'x';
        buf[i] = c;
    }
    buf[i] = '\0';
    if (js_date_parse_isostring(buf, fields, &is_local)
    ||  js_date_parse_otherstring(buf, fields, &is_local)) {
        static int const field_max[6] = { 0, 11, 31, 24, 59, 59 };
        bool valid = true;
        /* check field maximum values */
        for (i = 1; i < 6; i++) {
            if (fields[i] > field_max[i])
                valid = false;
        }
        /* special case 24:00:00.000 */
        if (fields[3] == 24 && (fields[4] | fields[5] | fields[6]))
            valid = false;
        if (valid) {
            for(i = 0; i < 7; i++)
                fields1[i] = fields[i];
            d = set_date_fields(fields1, is_local) - fields[8] * 60000;
            rv = js_float64(d);
        }
    }
    JS_FreeValue(ctx, s);
    return rv;
}

static JSValue js_Date_now(JSContext *ctx, JSValueConst this_val,
                           int argc, JSValueConst *argv)
{
    // now()
    return js_int64(date_now());
}

static JSValue js_date_Symbol_toPrimitive(JSContext *ctx, JSValueConst this_val,
                                          int argc, JSValueConst *argv)
{
    // Symbol_toPrimitive(hint)
    JSValueConst obj = this_val;
    JSAtom hint = JS_ATOM_NULL;
    int hint_num;

    if (!JS_IsObject(obj))
        return JS_ThrowTypeErrorNotAnObject(ctx);

    if (JS_IsString(argv[0])) {
        hint = JS_ValueToAtom(ctx, argv[0]);
        if (hint == JS_ATOM_NULL)
            return JS_EXCEPTION;
        JS_FreeAtom(ctx, hint);
    }
    switch (hint) {
    case JS_ATOM_number:
    case JS_ATOM_integer:
        hint_num = HINT_NUMBER;
        break;
    case JS_ATOM_string:
    case JS_ATOM_default:
        hint_num = HINT_STRING;
        break;
    default:
        return JS_ThrowTypeError(ctx, "invalid hint");
    }
    return JS_ToPrimitive(ctx, obj, hint_num | HINT_FORCE_ORDINARY);
}

static JSValue js_date_getTimezoneOffset(JSContext *ctx, JSValueConst this_val,
                                         int argc, JSValueConst *argv)
{
    // getTimezoneOffset()
    double v;

    if (JS_ThisTimeValue(ctx, &v, this_val))
        return JS_EXCEPTION;
    if (isnan(v))
        return JS_NAN;
    else
        /* assuming -8.64e15 <= v <= -8.64e15 */
        return js_int64(getTimezoneOffset((int64_t)trunc(v)));
}

static JSValue js_date_getTime(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv)
{
    // getTime()
    double v;

    if (JS_ThisTimeValue(ctx, &v, this_val))
        return JS_EXCEPTION;
    return js_float64(v);
}

static JSValue js_date_setTime(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv)
{
    // setTime(v)
    double v;

    if (JS_ThisTimeValue(ctx, &v, this_val) || JS_ToFloat64(ctx, &v, argv[0]))
        return JS_EXCEPTION;
    return JS_SetThisTimeValue(ctx, this_val, time_clip(v));
}

static JSValue js_date_setYear(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv)
{
    // setYear(y)
    double y;
    JSValue d, ret;

    if (JS_ThisTimeValue(ctx, &y, this_val) || JS_ToFloat64(ctx, &y, argv[0]))
        return JS_EXCEPTION;
    y = +y;
    if (isnan(y))
        return JS_SetThisTimeValue(ctx, this_val, y);
    if (isfinite(y)) {
        y = trunc(y);
        if (y >= 0 && y < 100)
            y += 1900;
    }
    d = js_float64(y);
    ret = set_date_field(ctx, this_val, 1, vc(&d), 0x011);
    JS_FreeValue(ctx, d);
    return ret;
}

static JSValue js_date_toJSON(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv)
{
    // toJSON(key)
    JSValue obj, tv, method, rv;
    double d;

    rv = JS_EXCEPTION;
    tv = JS_UNDEFINED;

    obj = JS_ToObject(ctx, this_val);
    tv = JS_ToPrimitive(ctx, obj, HINT_NUMBER);
    if (JS_IsException(tv))
        goto exception;
    if (JS_IsNumber(tv)) {
        if (JS_ToFloat64(ctx, &d, tv) < 0)
            goto exception;
        if (!isfinite(d)) {
            rv = JS_NULL;
            goto done;
        }
    }
    method = JS_GetPropertyStr(ctx, obj, "toISOString");
    if (JS_IsException(method))
        goto exception;
    if (!JS_IsFunction(ctx, method)) {
        JS_ThrowTypeError(ctx, "object needs toISOString method");
        JS_FreeValue(ctx, method);
        goto exception;
    }
    rv = JS_CallFree(ctx, method, obj, 0, NULL);
exception:
done:
    JS_FreeValue(ctx, obj);
    JS_FreeValue(ctx, tv);
    return rv;
}

static const JSCFunctionListEntry js_date_funcs[] = {
    JS_CFUNC_DEF("now", 0, js_Date_now ),
    JS_CFUNC_DEF("parse", 1, js_Date_parse ),
    JS_CFUNC_DEF("UTC", 7, js_Date_UTC ),
};

static const JSCFunctionListEntry js_date_proto_funcs[] = {
    JS_CFUNC_DEF("valueOf", 0, js_date_getTime ),
    JS_CFUNC_MAGIC_DEF("toString", 0, get_date_string, 0x13 ),
    JS_CFUNC_DEF("[Symbol.toPrimitive]", 1, js_date_Symbol_toPrimitive ),
    JS_CFUNC_MAGIC_DEF("toUTCString", 0, get_date_string, 0x03 ),
    JS_ALIAS_DEF("toGMTString", "toUTCString" ),
    JS_CFUNC_MAGIC_DEF("toISOString", 0, get_date_string, 0x23 ),
    JS_CFUNC_MAGIC_DEF("toDateString", 0, get_date_string, 0x11 ),
    JS_CFUNC_MAGIC_DEF("toTimeString", 0, get_date_string, 0x12 ),
    JS_CFUNC_MAGIC_DEF("toLocaleString", 0, get_date_string, 0x33 ),
    JS_CFUNC_MAGIC_DEF("toLocaleDateString", 0, get_date_string, 0x31 ),
    JS_CFUNC_MAGIC_DEF("toLocaleTimeString", 0, get_date_string, 0x32 ),
    JS_CFUNC_DEF("getTimezoneOffset", 0, js_date_getTimezoneOffset ),
    JS_CFUNC_DEF("getTime", 0, js_date_getTime ),
    JS_CFUNC_MAGIC_DEF("getYear", 0, get_date_field, 0x101 ),
    JS_CFUNC_MAGIC_DEF("getFullYear", 0, get_date_field, 0x01 ),
    JS_CFUNC_MAGIC_DEF("getUTCFullYear", 0, get_date_field, 0x00 ),
    JS_CFUNC_MAGIC_DEF("getMonth", 0, get_date_field, 0x11 ),
    JS_CFUNC_MAGIC_DEF("getUTCMonth", 0, get_date_field, 0x10 ),
    JS_CFUNC_MAGIC_DEF("getDate", 0, get_date_field, 0x21 ),
    JS_CFUNC_MAGIC_DEF("getUTCDate", 0, get_date_field, 0x20 ),
    JS_CFUNC_MAGIC_DEF("getHours", 0, get_date_field, 0x31 ),
    JS_CFUNC_MAGIC_DEF("getUTCHours", 0, get_date_field, 0x30 ),
    JS_CFUNC_MAGIC_DEF("getMinutes", 0, get_date_field, 0x41 ),
    JS_CFUNC_MAGIC_DEF("getUTCMinutes", 0, get_date_field, 0x40 ),
    JS_CFUNC_MAGIC_DEF("getSeconds", 0, get_date_field, 0x51 ),
    JS_CFUNC_MAGIC_DEF("getUTCSeconds", 0, get_date_field, 0x50 ),
    JS_CFUNC_MAGIC_DEF("getMilliseconds", 0, get_date_field, 0x61 ),
    JS_CFUNC_MAGIC_DEF("getUTCMilliseconds", 0, get_date_field, 0x60 ),
    JS_CFUNC_MAGIC_DEF("getDay", 0, get_date_field, 0x71 ),
    JS_CFUNC_MAGIC_DEF("getUTCDay", 0, get_date_field, 0x70 ),
    JS_CFUNC_DEF("setTime", 1, js_date_setTime ),
    JS_CFUNC_MAGIC_DEF("setMilliseconds", 1, set_date_field, 0x671 ),
    JS_CFUNC_MAGIC_DEF("setUTCMilliseconds", 1, set_date_field, 0x670 ),
    JS_CFUNC_MAGIC_DEF("setSeconds", 2, set_date_field, 0x571 ),
    JS_CFUNC_MAGIC_DEF("setUTCSeconds", 2, set_date_field, 0x570 ),
    JS_CFUNC_MAGIC_DEF("setMinutes", 3, set_date_field, 0x471 ),
    JS_CFUNC_MAGIC_DEF("setUTCMinutes", 3, set_date_field, 0x470 ),
    JS_CFUNC_MAGIC_DEF("setHours", 4, set_date_field, 0x371 ),
    JS_CFUNC_MAGIC_DEF("setUTCHours", 4, set_date_field, 0x370 ),
    JS_CFUNC_MAGIC_DEF("setDate", 1, set_date_field, 0x231 ),
    JS_CFUNC_MAGIC_DEF("setUTCDate", 1, set_date_field, 0x230 ),
    JS_CFUNC_MAGIC_DEF("setMonth", 2, set_date_field, 0x131 ),
    JS_CFUNC_MAGIC_DEF("setUTCMonth", 2, set_date_field, 0x130 ),
    JS_CFUNC_DEF("setYear", 1, js_date_setYear ),
    JS_CFUNC_MAGIC_DEF("setFullYear", 3, set_date_field, 0x031 ),
    JS_CFUNC_MAGIC_DEF("setUTCFullYear", 3, set_date_field, 0x030 ),
    JS_CFUNC_DEF("toJSON", 1, js_date_toJSON ),
};

JSValue JS_NewDate(JSContext *ctx, double epoch_ms)
{
    JSValue obj = js_create_from_ctor(ctx, JS_UNDEFINED, JS_CLASS_DATE);
    if (JS_IsException(obj))
        return JS_EXCEPTION;
    JS_SetObjectData(ctx, obj, js_float64(time_clip(epoch_ms)));
    return obj;
}

bool JS_IsDate(JSValueConst v)
{
    if (JS_VALUE_GET_TAG(v) != JS_TAG_OBJECT)
        return false;
    return JS_VALUE_GET_OBJ(v)->class_id == JS_CLASS_DATE;
}

int JS_AddIntrinsicDate(JSContext *ctx)
{
    JSValue obj;

    obj = JS_NewCConstructor(ctx, JS_CLASS_DATE, "Date",
                             js_date_constructor, 7, JS_CFUNC_constructor_or_func, 0,
                             JS_UNDEFINED,
                             js_date_funcs, countof(js_date_funcs),
                             js_date_proto_funcs, countof(js_date_proto_funcs),
                             0);
    if (JS_IsException(obj))
        return -1;
    JS_FreeValue(ctx, obj);
    return 0;
}

/* eval */

int JS_AddIntrinsicEval(JSContext *ctx)
{
#ifndef QJS_DISABLE_PARSER
    ctx->eval_internal = __JS_EvalInternal;
#endif // QJS_DISABLE_PARSER
    return 0;
}

/* BigInt */

static JSValue JS_ToBigIntCtorFree(JSContext *ctx, JSValue val)
{
    uint32_t tag;

 redo:
    tag = JS_VALUE_GET_NORM_TAG(val);
    switch(tag) {
    case JS_TAG_INT:
    case JS_TAG_BOOL:
        val = JS_NewBigInt64(ctx, JS_VALUE_GET_INT(val));
        break;
    case JS_TAG_SHORT_BIG_INT:
    case JS_TAG_BIG_INT:
        break;
    case JS_TAG_FLOAT64:
        {
            double d = JS_VALUE_GET_FLOAT64(val);
            JSBigInt *r;
            int res;
            r = js_bigint_from_float64(ctx, &res, d);
            if (!r) {
                if (res == 0) {
                    val = JS_EXCEPTION;
                } else if (res == 1) {
                    val = JS_ThrowRangeError(ctx, "cannot convert to BigInt: not an integer");
                } else {
                    val = JS_ThrowRangeError(ctx, "cannot convert NaN or Infinity to BigInt");                }
            } else {
                val = JS_CompactBigInt(ctx, r);
            }
        }
        break;
    case JS_TAG_STRING:
    case JS_TAG_STRING_ROPE:
        val = JS_StringToBigIntErr(ctx, val);
        break;
    case JS_TAG_OBJECT:
        val = JS_ToPrimitiveFree(ctx, val, HINT_NUMBER);
        if (JS_IsException(val))
            break;
        goto redo;
    case JS_TAG_NULL:
    case JS_TAG_UNDEFINED:
    default:
        JS_FreeValue(ctx, val);
        return JS_ThrowTypeError(ctx, "cannot convert to BigInt");
    }
    return val;
}

static JSValue js_bigint_constructor(JSContext *ctx,
                                     JSValueConst new_target,
                                     int argc, JSValueConst *argv)
{
    if (!JS_IsUndefined(new_target))
        return JS_ThrowTypeErrorNotAConstructor(ctx, new_target);
    return JS_ToBigIntCtorFree(ctx, js_dup(argv[0]));
}

static JSValue js_thisBigIntValue(JSContext *ctx, JSValueConst this_val)
{
    if (JS_IsBigInt(this_val))
        return js_dup(this_val);

    if (JS_VALUE_GET_TAG(this_val) == JS_TAG_OBJECT) {
        JSObject *p = JS_VALUE_GET_OBJ(this_val);
        if (p->class_id == JS_CLASS_BIG_INT) {
            if (JS_IsBigInt(p->u.object_data))
                return js_dup(p->u.object_data);
        }
    }
    return JS_ThrowTypeError(ctx, "not a BigInt");
}

static JSValue js_bigint_toString(JSContext *ctx, JSValueConst this_val,
                                  int argc, JSValueConst *argv)
{
    JSValue val;
    int base;
    JSValue ret;

    val = js_thisBigIntValue(ctx, this_val);
    if (JS_IsException(val))
        return val;
    if (argc == 0 || JS_IsUndefined(argv[0])) {
        base = 10;
    } else {
        base = js_get_radix(ctx, argv[0]);
        if (base < 0)
            goto fail;
    }
    ret = js_bigint_to_string1(ctx, val, base);
    JS_FreeValue(ctx, val);
    return ret;
 fail:
    JS_FreeValue(ctx, val);
    return JS_EXCEPTION;
}

static JSValue js_bigint_valueOf(JSContext *ctx, JSValueConst this_val,
                                 int argc, JSValueConst *argv)
{
    return js_thisBigIntValue(ctx, this_val);
}

static JSValue js_bigint_asUintN(JSContext *ctx,
                                  JSValueConst this_val,
                                  int argc, JSValueConst *argv, int asIntN)
{
    uint64_t bits;
    JSValue res, a;

    if (JS_ToIndex(ctx, &bits, argv[0]))
        return JS_EXCEPTION;
    a = JS_ToBigInt(ctx, argv[1]);
    if (JS_IsException(a))
        return JS_EXCEPTION;
    if (bits == 0) {
        JS_FreeValue(ctx, a);
        res = __JS_NewShortBigInt(ctx, 0);
    } else if (JS_VALUE_GET_TAG(a) == JS_TAG_SHORT_BIG_INT) {
        /* fast case */
        js_slimb_t sv = JS_VALUE_GET_SHORT_BIG_INT(a);
        if (bits >= JS_SHORT_BIG_INT_BITS && (asIntN || sv >= 0)) {
            res = a;
        } else if (bits < JS_SHORT_BIG_INT_BITS) {
            uint64_t v;
            int shift;
            shift = 64 - bits;
            v = sv;
            v = v << shift;
            if (asIntN)
                v = (int64_t)v >> shift;
            else
                v = v >> shift;
            res = __JS_NewShortBigInt(ctx, v);
        } else {
            JSBigInt *r;
            uint64_t len64 = (bits + JS_LIMB_BITS - 1) / JS_LIMB_BITS;
            int len, shift, i;

            if (len64 > JS_BIGINT_MAX_SIZE) {
                JS_FreeValue(ctx, a);
                return JS_ThrowRangeError(ctx, "BigInt is too large to allocate");
            }
            len = len64;
            r = js_bigint_new(ctx, len);
            if (!r) {
                JS_FreeValue(ctx, a);
                return JS_EXCEPTION;
            }
            r->len = len;
            r->tab[0] = sv;
            for(i = 1; i < len; i++)
                r->tab[i] = -1;
            shift = (-bits) & (JS_LIMB_BITS - 1);
            r->tab[len - 1] = (r->tab[len - 1] << shift) >> shift;
            r = js_bigint_extend(ctx, r, 0);
            JS_FreeValue(ctx, a);
            if (!r)
                return JS_EXCEPTION;
            res = JS_CompactBigInt(ctx, r);
        }
    } else {
        JSBigInt *r, *p = JS_VALUE_GET_PTR(a);
        int is_neg = js_bigint_sign(p);
        if (bits >= (uint64_t)p->len * JS_LIMB_BITS &&
            (asIntN || !is_neg)) {
            res = a;
        } else {
            uint64_t len64 = (bits + JS_LIMB_BITS - 1) / JS_LIMB_BITS;
            int len, shift, i;
            js_limb_t v;
            if (len64 > JS_BIGINT_MAX_SIZE) {
                JS_FreeValue(ctx, a);
                return JS_ThrowRangeError(ctx, "BigInt is too large to allocate");
            }
            len = len64;
            r = js_bigint_new(ctx, len);
            if (!r) {
                JS_FreeValue(ctx, a);
                return JS_EXCEPTION;
            }
            r->len = len;
            for(i = 0; i < len - 1; i++)
                r->tab[i] = i < p->len ? p->tab[i] : -is_neg;
            shift = (-bits) & (JS_LIMB_BITS - 1);
            /* 0 <= shift <= JS_LIMB_BITS - 1 */
            v = (len - 1 < p->len ? p->tab[len - 1] : -is_neg) << shift;
            if (asIntN)
                v = (js_slimb_t)v >> shift;
            else
                v = v >> shift;
            r->tab[len - 1] = v;
            if (!asIntN)
                r = js_bigint_extend(ctx, r, 0);
            if (!r) {
                JS_FreeValue(ctx, a);
                return JS_EXCEPTION;
            }
            r = js_bigint_normalize(ctx, r);
            JS_FreeValue(ctx, a);
            res = JS_CompactBigInt(ctx, r);
        }
    }
    return res;
}

static const JSCFunctionListEntry js_bigint_funcs[] = {
    JS_CFUNC_MAGIC_DEF("asUintN", 2, js_bigint_asUintN, 0 ),
    JS_CFUNC_MAGIC_DEF("asIntN", 2, js_bigint_asUintN, 1 ),
};

static const JSCFunctionListEntry js_bigint_proto_funcs[] = {
    JS_CFUNC_DEF("toString", 0, js_bigint_toString ),
    JS_CFUNC_DEF("valueOf", 0, js_bigint_valueOf ),
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "BigInt", JS_PROP_CONFIGURABLE ),
};

int JS_AddIntrinsicBigInt(JSContext *ctx)
{
    JSValue obj1;

    obj1 = JS_NewCConstructor(ctx, JS_CLASS_BIG_INT, "BigInt",
                              js_bigint_constructor, 1, JS_CFUNC_constructor_or_func, 0,
                              JS_UNDEFINED,
                              js_bigint_funcs, countof(js_bigint_funcs),
                              js_bigint_proto_funcs, countof(js_bigint_proto_funcs),
                              0);
    if (JS_IsException(obj1))
        return -1;
    JS_FreeValue(ctx, obj1);
    return 0;
}

static const char * const native_error_name[JS_NATIVE_ERROR_COUNT] = {
    "EvalError", "RangeError", "ReferenceError",
    "SyntaxError", "TypeError", "URIError",
    "InternalError", "AggregateError",
    "SuppressedError",
};

/* Minimum amount of objects to be able to compile code and display
   error messages. No JSAtom should be allocated by this function. */
/* Minimum amount of objects to be able to compile code and display
   error messages. */
static int JS_AddIntrinsicBasicObjects(JSContext *ctx)
{
    JSValue proto;
    int i;

    /* warning: ordering is tricky */
    ctx->class_proto[JS_CLASS_OBJECT] =
        JS_NewObjectProtoClassAlloc(ctx, JS_NULL, JS_CLASS_OBJECT,
                                    countof(js_object_proto_funcs) + 1);
    if (JS_IsException(ctx->class_proto[JS_CLASS_OBJECT]))
        return -1;

    /* 2 more properties: caller and arguments */
    ctx->function_proto = JS_NewCFunction3(ctx, js_function_proto, "", 0,
                                           JS_CFUNC_generic, 0,
                                           ctx->class_proto[JS_CLASS_OBJECT],
                                           countof(js_function_proto_funcs) + 3 + 2);
    if (JS_IsException(ctx->function_proto))
        return -1;
    ctx->class_proto[JS_CLASS_BYTECODE_FUNCTION] = js_dup(ctx->function_proto);

    ctx->global_obj = JS_NewObjectProtoClassAlloc(ctx, ctx->class_proto[JS_CLASS_OBJECT],
                                                  JS_CLASS_OBJECT, 64);
    if (JS_IsException(ctx->global_obj))
        return -1;
    ctx->global_var_obj = JS_NewObjectProtoClassAlloc(ctx, JS_NULL,
                                                      JS_CLASS_OBJECT, 16);
    if (JS_IsException(ctx->global_var_obj))
        return -1;

    ctx->class_proto[JS_CLASS_ERROR] = JS_NewObject(ctx);
    JS_SetPropertyFunctionList(ctx, ctx->class_proto[JS_CLASS_ERROR],
                               js_error_proto_funcs,
                               countof(js_error_proto_funcs));

    for(i = 0; i < JS_NATIVE_ERROR_COUNT; i++) {
        proto = JS_NewObjectProto(ctx, ctx->class_proto[JS_CLASS_ERROR]);
        JS_DefinePropertyValue(ctx, proto, JS_ATOM_name,
                               JS_NewAtomString(ctx, native_error_name[i]),
                               JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
        JS_DefinePropertyValue(ctx, proto, JS_ATOM_message,
                               js_empty_string(ctx->rt),
                               JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
        ctx->native_error_proto[i] = proto;
    }

    /* the array prototype is an array */
    ctx->class_proto[JS_CLASS_ARRAY] =
        JS_NewObjectProtoClass(ctx, ctx->class_proto[JS_CLASS_OBJECT],
                               JS_CLASS_ARRAY);
    ctx->std_array_prototype = true;

    static const JSShapeProperty array_props[] = {
        {.atom=JS_ATOM_length,          .flags=JS_PROP_WRITABLE|JS_PROP_LENGTH},
    };
    static const JSShapeProperty arguments_props[] = {
        {.atom=JS_ATOM_length,          .flags=JS_PROP_WRITABLE|JS_PROP_CONFIGURABLE},
        {.atom=JS_ATOM_Symbol_iterator, .flags=JS_PROP_WRITABLE|JS_PROP_CONFIGURABLE},
        {.atom=JS_ATOM_callee,          .flags=JS_PROP_GETSET},
    };
    static const JSShapeProperty mapped_arguments_props[] = {
        {.atom=JS_ATOM_length,          .flags=JS_PROP_WRITABLE|JS_PROP_CONFIGURABLE},
        {.atom=JS_ATOM_Symbol_iterator, .flags=JS_PROP_WRITABLE|JS_PROP_CONFIGURABLE},
        {.atom=JS_ATOM_callee,          .flags=JS_PROP_WRITABLE|JS_PROP_CONFIGURABLE},
    };
    if (js_new_shape_with(ctx, &ctx->array_shape,
                          ctx->class_proto[JS_CLASS_ARRAY],
                          countof(array_props), array_props)) {
        return -1;
    }
    if (js_new_shape_with(ctx, &ctx->arguments_shape,
                          ctx->class_proto[JS_CLASS_OBJECT],
                          countof(arguments_props), arguments_props)) {
        return -1;
    }
    if (js_new_shape_with(ctx, &ctx->mapped_arguments_shape,
                          ctx->class_proto[JS_CLASS_OBJECT],
                          countof(mapped_arguments_props), mapped_arguments_props)) {
        return -1;
    }

    return 0;
}

int JS_AddIntrinsicBaseObjects(JSContext *ctx)
{
    JSValue obj1, obj2;
    JSCFunctionType ft;

    ctx->throw_type_error = JS_NewCFunction(ctx, js_throw_type_error, NULL, 0);
    if (JS_IsException(ctx->throw_type_error))
        return -1;
    /* add caller and arguments properties to throw a TypeError */
    if (JS_DefineProperty(ctx, ctx->function_proto, JS_ATOM_caller, JS_UNDEFINED,
                          ctx->throw_type_error, ctx->throw_type_error,
                          JS_PROP_HAS_GET | JS_PROP_HAS_SET |
                          JS_PROP_HAS_CONFIGURABLE | JS_PROP_CONFIGURABLE) < 0)
        return -1;
    if (JS_DefineProperty(ctx, ctx->function_proto, JS_ATOM_arguments, JS_UNDEFINED,
                          ctx->throw_type_error, ctx->throw_type_error,
                          JS_PROP_HAS_GET | JS_PROP_HAS_SET |
                          JS_PROP_HAS_CONFIGURABLE | JS_PROP_CONFIGURABLE) < 0)
        return -1;
    JS_FreeValue(ctx, js_object_seal(ctx, JS_UNDEFINED, 1, vc(&ctx->throw_type_error), 1));

    /* Object */
    obj1 = JS_NewCConstructor(ctx, JS_CLASS_OBJECT, "Object",
                              js_object_constructor, 1, JS_CFUNC_constructor_or_func, 0,
                              JS_UNDEFINED,
                              js_object_funcs, countof(js_object_funcs),
                              js_object_proto_funcs, countof(js_object_proto_funcs),
                              JS_NEW_CTOR_PROTO_EXIST);
    if (JS_IsException(obj1))
        return -1;
    JS_FreeValue(ctx, obj1);

    /* Function */
    ft.generic_magic = js_function_constructor;
    obj1 = JS_NewCConstructor(ctx, JS_CLASS_BYTECODE_FUNCTION, "Function",
                              ft.generic, 1, JS_CFUNC_constructor_or_func_magic, JS_FUNC_NORMAL,
                              JS_UNDEFINED,
                              NULL, 0,
                              js_function_proto_funcs, countof(js_function_proto_funcs),
                              JS_NEW_CTOR_PROTO_EXIST);
    if (JS_IsException(obj1))
        return -1;
    ctx->function_ctor = obj1;

    /* Error */
    ft.generic_magic = js_error_constructor;
    ctx->error_ctor = JS_NewCFunctionMagic(ctx, js_error_constructor,
                                           "Error", 1, JS_CFUNC_constructor_or_func_magic, -1);
    if (JS_IsException(ctx->error_ctor))
        return -1;
    JS_NewGlobalCConstructor2(ctx, js_dup(ctx->error_ctor),
                              "Error", ctx->class_proto[JS_CLASS_ERROR]);
    if (JS_SetPropertyFunctionList(ctx, ctx->error_ctor, js_error_funcs, countof(js_error_funcs)))
        return -1;

    for(int i = 0; i < JS_NATIVE_ERROR_COUNT; i++) {
        JSValue func_obj;
        int n_args;
        switch (i) {
        case JS_AGGREGATE_ERROR:
            n_args = 2;
            break;
        case JS_SUPPRESSED_ERROR:
            n_args = 3;
            break;
        default:
            n_args = 1;
        }
        func_obj = JS_NewCFunction3(ctx, ft.generic,
                                    native_error_name[i], n_args,
                                    JS_CFUNC_constructor_or_func_magic, i,
                                    ctx->error_ctor, 0);
        if (JS_IsException(func_obj))
            return -1;
        JS_NewGlobalCConstructor2(ctx, func_obj, native_error_name[i],
                                  ctx->native_error_proto[i]);
    }

    /* CallSite */
    if (_JS_AddIntrinsicCallSite(ctx))
        return -1;

    /* Iterator */
    obj2 = JS_NewCConstructor(ctx, JS_CLASS_ITERATOR, "Iterator",
                              js_iterator_constructor, 0, JS_CFUNC_constructor_or_func, 0,
                              JS_UNDEFINED,
                              js_iterator_funcs, countof(js_iterator_funcs),
                              js_iterator_proto_funcs, countof(js_iterator_proto_funcs),
                              0);
    if (JS_IsException(obj2))
        return -1;
    // quirk: Iterator.prototype.constructor is an accessor property. The getter
    // (magic == 0) returns %Iterator%; the setter (magic == 1, length 1)
    // implements SetterThatIgnoresPrototypeProperties. They must be separate
    // function objects so that magic, not argc, distinguishes get from set.
    // TODO(bnoordhuis) mildly inefficient because JS_NewCConstructor
    // first creates a .constructor value property that we then replace with
    // an accessor
    {
        JSValue getter, setter;
        getter = JS_NewCFunctionData(ctx, js_iterator_constructor_getset,
                                     0, 0, 1, vc(&obj2));
        if (JS_IsException(getter)) {
            JS_FreeValue(ctx, obj2);
            return -1;
        }
        setter = JS_NewCFunctionData(ctx, js_iterator_constructor_getset,
                                     1, 1, 1, vc(&obj2));
        if (JS_IsException(setter)) {
            JS_FreeValue(ctx, getter);
            JS_FreeValue(ctx, obj2);
            return -1;
        }
        ctx->iterator_ctor_getset = js_dup(getter);
        if (JS_DefineProperty(ctx, ctx->class_proto[JS_CLASS_ITERATOR],
                              JS_ATOM_constructor, JS_UNDEFINED,
                              getter, setter,
                              JS_PROP_HAS_GET | JS_PROP_HAS_SET | JS_PROP_CONFIGURABLE) < 0) {
            JS_FreeValue(ctx, getter);
            JS_FreeValue(ctx, setter);
            JS_FreeValue(ctx, obj2);
            return -1;
        }
        JS_FreeValue(ctx, getter);
        JS_FreeValue(ctx, setter);
    }
    ctx->iterator_ctor = obj2;
    JS_DefineAutoInitProperty(ctx, obj2, JS_ATOM_zip, JS_AUTOINIT_ID_BYTECODE,
                              (void *)(uintptr_t)JS_BUILTIN_ITERATOR_ZIP,
                              JS_PROP_WRITABLE|JS_PROP_CONFIGURABLE);
    JS_DefineAutoInitProperty(ctx, obj2, JS_ATOM_zipKeyed, JS_AUTOINIT_ID_BYTECODE,
                              (void *)(uintptr_t)JS_BUILTIN_ITERATOR_ZIP_KEYED,
                              JS_PROP_WRITABLE|JS_PROP_CONFIGURABLE);

    ctx->class_proto[JS_CLASS_ITERATOR_HELPER] =
        JS_NewObjectProtoList(ctx, ctx->class_proto[JS_CLASS_ITERATOR],
                              js_iterator_helper_proto_funcs,
                              countof(js_iterator_helper_proto_funcs));
    if (JS_IsException(ctx->class_proto[JS_CLASS_ITERATOR_HELPER]))
        return -1;

    /* Iterator.concat() returns an Iterator Helper */
    ctx->class_proto[JS_CLASS_ITERATOR_CONCAT] =
        js_dup(ctx->class_proto[JS_CLASS_ITERATOR_HELPER]);

    ctx->class_proto[JS_CLASS_ITERATOR_WRAP] =
        JS_NewObjectProtoList(ctx, ctx->class_proto[JS_CLASS_ITERATOR],
                              js_iterator_wrap_proto_funcs,
                              countof(js_iterator_wrap_proto_funcs));
    if (JS_IsException(ctx->class_proto[JS_CLASS_ITERATOR_WRAP]))
        return -1;

    /* Array */
    obj1 = JS_NewCConstructor(ctx, JS_CLASS_ARRAY, "Array",
                              js_array_constructor, 1, JS_CFUNC_constructor_or_func, 0,
                              JS_UNDEFINED,
                              js_array_funcs, countof(js_array_funcs),
                              js_array_proto_funcs, countof(js_array_proto_funcs),
                              JS_NEW_CTOR_PROTO_EXIST);
    if (JS_IsException(obj1))
        return -1;
    ctx->array_ctor = obj1;
    JS_DefineAutoInitProperty(ctx, obj1, JS_ATOM_fromAsync,
                              JS_AUTOINIT_ID_BYTECODE,
                              (void *)(uintptr_t)JS_BUILTIN_ARRAY_FROMASYNC,
                              JS_PROP_WRITABLE|JS_PROP_CONFIGURABLE);

    /* needed to initialize arguments[Symbol.iterator] */
    ctx->array_proto_values =
        JS_GetProperty(ctx, ctx->class_proto[JS_CLASS_ARRAY], JS_ATOM_values);
    if (JS_IsException(ctx->array_proto_values))
        return -1;

    ctx->class_proto[JS_CLASS_ARRAY_ITERATOR] =
        JS_NewObjectProtoList(ctx, ctx->class_proto[JS_CLASS_ITERATOR],
                              js_array_iterator_proto_funcs,
                              countof(js_array_iterator_proto_funcs));
    if (JS_IsException(ctx->class_proto[JS_CLASS_ARRAY_ITERATOR]))
        return -1;

    /* parseFloat and parseInteger must be defined before Number
       because of the Number.parseFloat and Number.parseInteger
       aliases */
    if (JS_SetPropertyFunctionList(ctx, ctx->global_obj, js_global_funcs,
                                   countof(js_global_funcs)))
        return -1;

    /* Number */
    obj1 = JS_NewCConstructor(ctx, JS_CLASS_NUMBER, "Number",
                              js_number_constructor, 1, JS_CFUNC_constructor_or_func, 0,
                              JS_UNDEFINED,
                              js_number_funcs, countof(js_number_funcs),
                              js_number_proto_funcs, countof(js_number_proto_funcs),
                              JS_NEW_CTOR_PROTO_CLASS);
    if (JS_IsException(obj1))
        return -1;
    JS_FreeValue(ctx, obj1);
    if (JS_SetObjectData(ctx, ctx->class_proto[JS_CLASS_NUMBER], js_int32(0)))
        return -1;

    /* Boolean */
    obj1 = JS_NewCConstructor(ctx, JS_CLASS_BOOLEAN, "Boolean",
                              js_boolean_constructor, 1, JS_CFUNC_constructor_or_func, 0,
                              JS_UNDEFINED,
                              NULL, 0,
                              js_boolean_proto_funcs, countof(js_boolean_proto_funcs),
                              JS_NEW_CTOR_PROTO_CLASS);
    if (JS_IsException(obj1))
        return -1;
    JS_FreeValue(ctx, obj1);
    if (JS_SetObjectData(ctx, ctx->class_proto[JS_CLASS_BOOLEAN], JS_FALSE))
        return -1;

    /* String */
    obj1 = JS_NewCConstructor(ctx, JS_CLASS_STRING, "String",
                              js_string_constructor, 1, JS_CFUNC_constructor_or_func, 0,
                              JS_UNDEFINED,
                              js_string_funcs, countof(js_string_funcs),
                              js_string_proto_funcs, countof(js_string_proto_funcs),
                              JS_NEW_CTOR_PROTO_CLASS);
    if (JS_IsException(obj1))
        return -1;
    JS_FreeValue(ctx, obj1);
    if (JS_SetObjectData(ctx, ctx->class_proto[JS_CLASS_STRING], js_empty_string(ctx->rt)))
        return -1;

    ctx->class_proto[JS_CLASS_STRING_ITERATOR] =
        JS_NewObjectProtoList(ctx, ctx->class_proto[JS_CLASS_ITERATOR],
                              js_string_iterator_proto_funcs,
                              countof(js_string_iterator_proto_funcs));
    if (JS_IsException(ctx->class_proto[JS_CLASS_STRING_ITERATOR]))
        return -1;

    /* Math: create as autoinit object */
    if (JS_SetPropertyFunctionList(ctx, ctx->global_obj, js_math_obj, countof(js_math_obj)))
        return -1;

    /* ES6 Reflect: create as autoinit object */
    if (JS_SetPropertyFunctionList(ctx, ctx->global_obj, js_reflect_obj, countof(js_reflect_obj)))
        return -1;

    /* ES6 Symbol */
    obj1 = JS_NewCConstructor(ctx, JS_CLASS_SYMBOL, "Symbol",
                              js_symbol_constructor, 0, JS_CFUNC_constructor_or_func, 0,
                              JS_UNDEFINED,
                              js_symbol_funcs, countof(js_symbol_funcs),
                              js_symbol_proto_funcs, countof(js_symbol_proto_funcs),
                              0);
    if (JS_IsException(obj1))
        return -1;
    JS_FreeValue(ctx, obj1);

    /* ES6 Generator */
    ctx->class_proto[JS_CLASS_GENERATOR] =
        JS_NewObjectProtoList(ctx, ctx->class_proto[JS_CLASS_ITERATOR],
                              js_generator_proto_funcs,
                              countof(js_generator_proto_funcs));
    if (JS_IsException(ctx->class_proto[JS_CLASS_GENERATOR]))
        return -1;

    ft.generic_magic = js_function_constructor;
    obj1 = JS_NewCConstructor(ctx, JS_CLASS_GENERATOR_FUNCTION, "GeneratorFunction",
                              ft.generic, 1, JS_CFUNC_constructor_or_func_magic, JS_FUNC_GENERATOR,
                              ctx->function_ctor,
                              NULL, 0,
                              js_generator_function_proto_funcs,
                              countof(js_generator_function_proto_funcs),
                              JS_NEW_CTOR_NO_GLOBAL | JS_NEW_CTOR_READONLY);
    if (JS_IsException(obj1))
        return -1;
    JS_FreeValue(ctx, obj1);
    if (JS_SetConstructor2(ctx, ctx->class_proto[JS_CLASS_GENERATOR_FUNCTION],
                           ctx->class_proto[JS_CLASS_GENERATOR],
                           JS_PROP_CONFIGURABLE, JS_PROP_CONFIGURABLE))
        return -1;

    /* explicit resource management */
    ctx->class_proto[JS_CLASS_DISPOSABLE_STACK] = JS_NewObject(ctx);
    JS_SetPropertyFunctionList(ctx, ctx->class_proto[JS_CLASS_DISPOSABLE_STACK],
                               js_disposable_stack_proto_funcs,
                               countof(js_disposable_stack_proto_funcs));
    JS_NewGlobalCConstructorMagic(ctx, "DisposableStack",
                                  js_disposable_stack_constructor, 0,
                                  ctx->class_proto[JS_CLASS_DISPOSABLE_STACK],
                                  JS_CLASS_DISPOSABLE_STACK);

    /* global properties */
    ctx->eval_obj = JS_GetProperty(ctx, ctx->global_obj, JS_ATOM_eval);
    if (JS_IsException(ctx->eval_obj))
        return -1;

    if (JS_DefinePropertyValue(ctx, ctx->global_obj, JS_ATOM_globalThis,
                               js_dup(ctx->global_obj),
                               JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE) < 0)
        return -1;

    /* BigInt */
    if (JS_AddIntrinsicBigInt(ctx))
        return -1;
    return 0;
}

/* Typed Arrays */

static uint8_t const typed_array_size_log2[JS_TYPED_ARRAY_COUNT] = {
    0, 0, 0, 1, 1, 2, 2,
    3, 3,                   // BigInt64Array, BigUint64Array
    1, 2, 3                 // Float16Array, Float32Array, Float64Array
};

static JSValue js_array_buffer_constructor3(JSContext *ctx,
                                            JSValueConst new_target,
                                            uint64_t len, uint64_t *max_len,
                                            JSClassID class_id,
                                            uint8_t *buf,
                                            JSReallocArrayBufferDataFunc *realloc_func,
                                            void *opaque, bool alloc_flag)
{
    JSRuntime *rt = ctx->rt;
    JSValue obj;
    JSArrayBuffer *abuf = NULL;
    uint64_t sab_alloc_len;

    // SABs commit their maximum size upfront and are therefore never
    // reallocated; everything else needs a way to resize the backing memory.
    // Not observable from JS land, only through C API misuse; JS code cannot
    // create externally managed buffers directly.
    if (!alloc_flag && buf && max_len && !realloc_func &&
        class_id != JS_CLASS_SHARED_ARRAY_BUFFER) {
        return JS_ThrowInternalError(ctx,
                                     "resizable ArrayBuffers require a "
                                     "realloc function");
    }
    obj = js_create_from_ctor(ctx, new_target, class_id);
    if (JS_IsException(obj))
        return obj;
    /* XXX: we are currently limited to 2 GB */
    if (len > INT32_MAX) {
        JS_ThrowRangeError(ctx, "invalid array buffer length");
        goto fail;
    }
    if (max_len && *max_len > INT32_MAX) {
        JS_ThrowRangeError(ctx, "invalid max array buffer length");
        goto fail;
    }
    if (alloc_flag && class_id == JS_CLASS_SHARED_ARRAY_BUFFER && max_len &&
        *max_len > len && !rt->sab_funcs.sab_alloc) {
        JS_ThrowTypeError(ctx,
                          "growable SharedArrayBuffer requires "
                          "SAB allocator hooks");
        goto fail;
    }
    abuf = js_malloc(ctx, sizeof(*abuf));
    if (!abuf)
        goto fail;
    abuf->byte_length = len;
    abuf->max_byte_length = max_len ? *max_len : -1;
    if (alloc_flag) {
        if (class_id == JS_CLASS_SHARED_ARRAY_BUFFER &&
            rt->sab_funcs.sab_alloc) {
            // TOOD(bnoordhuis) resizing backing memory for SABs atomically
            // is hard so we cheat and allocate |maxByteLength| bytes upfront
            sab_alloc_len = max_len ? *max_len : len;
            abuf->data = rt->sab_funcs.sab_alloc(rt->sab_funcs.sab_opaque,
                                                 max_int(sab_alloc_len, 1));
            if (!abuf->data)
                goto fail;
            memset(abuf->data, 0, sab_alloc_len);
        } else {
            /* the allocation must be done after the object creation */
            abuf->data = js_mallocz(ctx, max_int(len, 1));
            if (!abuf->data)
                goto fail;
        }
    } else {
        if (class_id == JS_CLASS_SHARED_ARRAY_BUFFER &&
            rt->sab_funcs.sab_dup) {
            rt->sab_funcs.sab_dup(rt->sab_funcs.sab_opaque, buf);
        }
        if (buf) {
            abuf->data = buf;
        } else {
            abuf->data = js_mallocz(ctx, 1);
            if (!abuf->data)
                goto fail;
            realloc_func = js_array_buffer_realloc;
        }
    }
    init_list_head(&abuf->array_list);
    abuf->detached = false;
    abuf->immutable = false;
    abuf->shared = (class_id == JS_CLASS_SHARED_ARRAY_BUFFER);
    abuf->opaque = opaque;
    abuf->realloc_func = realloc_func;
    if (alloc_flag && buf)
        memcpy(abuf->data, buf, len);
    JS_SetOpaqueInternal(obj, abuf);
    return obj;
 fail:
    JS_FreeValue(ctx, obj);
    js_free(ctx, abuf);
    return JS_EXCEPTION;
}

static void *js_array_buffer_realloc(JSRuntime *rt, void *opaque, void *ptr,
                                     size_t size)
{
    return js_realloc_rt(rt, ptr, size);
}

static JSValue js_array_buffer_constructor2(JSContext *ctx,
                                            JSValueConst new_target,
                                            uint64_t len, uint64_t *max_len,
                                            JSClassID class_id)
{
    return js_array_buffer_constructor3(ctx, new_target, len, max_len,
                                        class_id, NULL,
                                        js_array_buffer_realloc, NULL, true);
}

static JSValue js_array_buffer_constructor1(JSContext *ctx,
                                            JSValueConst new_target,
                                            uint64_t len, uint64_t *max_len)
{
    return js_array_buffer_constructor2(ctx, new_target, len, max_len,
                                        JS_CLASS_ARRAY_BUFFER);
}

JSValue JS_NewArrayBuffer(JSContext *ctx, uint8_t *buf, size_t len,
                          size_t max_len,
                          JSReallocArrayBufferDataFunc *realloc_func,
                          void *opaque, bool is_shared)
{
    JSClassID class_id =
        is_shared ? JS_CLASS_SHARED_ARRAY_BUFFER : JS_CLASS_ARRAY_BUFFER;
    uint64_t max_len64 = max_len, *pmax_len = NULL;

    /* a zero 'max_len' means the ArrayBuffer is not resizable */
    if (max_len > 0) {
        if (max_len < len)
            return JS_ThrowRangeError(ctx, "invalid max array buffer length");
        pmax_len = &max_len64;
    }
    return js_array_buffer_constructor3(ctx, JS_UNDEFINED, len, pmax_len,
                                        class_id, buf, realloc_func, opaque,
                                        false);
}

bool JS_IsArrayBuffer(JSValueConst obj) {
    return JS_GetClassID(obj) == JS_CLASS_ARRAY_BUFFER;
}

/* create a new ArrayBuffer of length 'len' and copy 'buf' to it */
JSValue JS_NewArrayBufferCopy(JSContext *ctx, const uint8_t *buf, size_t len)
{
    return js_array_buffer_constructor3(ctx, JS_UNDEFINED, len, NULL,
                                        JS_CLASS_ARRAY_BUFFER,
                                        (uint8_t *)buf,
                                        js_array_buffer_realloc, NULL,
                                        true);
}

static JSValue js_array_buffer_constructor0(JSContext *ctx, JSValueConst new_target,
                                            int argc, JSValueConst *argv,
                                            JSClassID class_id)
{
    uint64_t len, max_len, *pmax_len = NULL;
    JSValue obj, val;
    int64_t i;

    if (JS_ToIndex(ctx, &len, argv[0]))
        return JS_EXCEPTION;
    if (argc < 2)
        goto next;
    if (!JS_IsObject(argv[1]))
        goto next;
    obj = JS_ToObject(ctx, argv[1]);
    if (JS_IsException(obj))
        return JS_EXCEPTION;
    val = JS_GetProperty(ctx, obj, JS_ATOM_maxByteLength);
    JS_FreeValue(ctx, obj);
    if (JS_IsException(val))
        return JS_EXCEPTION;
    if (JS_IsUndefined(val))
        goto next;
    if (JS_ToInt64Free(ctx, &i, val))
        return JS_EXCEPTION;
    // don't have to check i < 0 because len >= 0
    if (len > i || i > MAX_SAFE_INTEGER)
        return JS_ThrowRangeError(ctx, "invalid array buffer max length");
    max_len = i;
    pmax_len = &max_len;
next:
    return js_array_buffer_constructor2(ctx, new_target, len, pmax_len,
                                        class_id);
}

static JSValue js_array_buffer_constructor(JSContext *ctx, JSValueConst new_target,
                                           int argc, JSValueConst *argv)
{
    return js_array_buffer_constructor0(ctx, new_target, argc, argv,
                                        JS_CLASS_ARRAY_BUFFER);
}

static JSValue js_shared_array_buffer_constructor(JSContext *ctx,
                                                  JSValueConst new_target,
                                                  int argc, JSValueConst *argv)
{
    return js_array_buffer_constructor0(ctx, new_target, argc, argv,
                                        JS_CLASS_SHARED_ARRAY_BUFFER);
}

/* also used for SharedArrayBuffer */
static void js_array_buffer_finalizer(JSRuntime *rt, JSValueConst val)
{
    JSObject *p = JS_VALUE_GET_OBJ(val);
    JSArrayBuffer *abuf = p->u.array_buffer;
    struct list_head *el, *el1;

    if (abuf) {
        /* The ArrayBuffer finalizer may be called before the typed
           array finalizers using it, so abuf->array_list is not
           necessarily empty. */
        list_for_each_safe(el, el1, &abuf->array_list) {
            JSTypedArray *ta;
            JSObject *p1;

            ta = list_entry(el, JSTypedArray, link);
            ta->link.prev = NULL;
            ta->link.next = NULL;
            p1 = ta->obj;
            /* Note: the typed array length and offset fields are not modified */
            if (p1->class_id != JS_CLASS_DATAVIEW) {
                p1->u.array.count = 0;
                p1->u.array.u.ptr = NULL;
            }
        }
        if (abuf->shared && rt->sab_funcs.sab_free) {
            rt->sab_funcs.sab_free(rt->sab_funcs.sab_opaque, abuf->data);
        } else {
            if (abuf->realloc_func)
                abuf->realloc_func(rt, abuf->opaque, abuf->data, 0);
        }
        js_free_rt(rt, abuf);
    }
}

static JSValue js_array_buffer_isView(JSContext *ctx,
                                      JSValueConst this_val,
                                      int argc, JSValueConst *argv)
{
    JSObject *p;

    if (JS_VALUE_GET_TAG(argv[0]) == JS_TAG_OBJECT) {
        p = JS_VALUE_GET_OBJ(argv[0]);
        return js_bool(is_typed_array(p->class_id) ||
                       p->class_id == JS_CLASS_DATAVIEW);
    }
    return JS_FALSE;
}

static const JSCFunctionListEntry js_array_buffer_funcs[] = {
    JS_CFUNC_DEF("isView", 1, js_array_buffer_isView ),
    JS_CGETSET_DEF("[Symbol.species]", js_get_this, NULL ),
};

static JSValue JS_ThrowTypeErrorDetachedArrayBuffer(JSContext *ctx)
{
    return JS_ThrowTypeError(ctx, "ArrayBuffer is detached");
}

static JSValue JS_ThrowTypeErrorImmutableArrayBuffer(JSContext *ctx)
{
    return JS_ThrowTypeError(ctx, "ArrayBuffer is immutable");
}

static JSValue JS_ThrowTypeErrorArrayBufferOOB(JSContext *ctx)
{
    return JS_ThrowTypeError(ctx, "ArrayBuffer is detached or resized");
}

// #sec-get-arraybuffer.prototype.detached
static JSValue js_array_buffer_get_detached(JSContext *ctx,
                                            JSValueConst this_val)
{
    JSArrayBuffer *abuf = JS_GetOpaque2(ctx, this_val, JS_CLASS_ARRAY_BUFFER);
    if (!abuf)
        return JS_EXCEPTION;
    if (abuf->shared)
        return JS_ThrowTypeError(ctx, "detached called on SharedArrayBuffer");
    return js_bool(abuf->detached);
}

static JSValue js_array_buffer_get_immutable(JSContext *ctx,
                                             JSValueConst this_val)
{
    JSArrayBuffer *abuf = JS_GetOpaque2(ctx, this_val, JS_CLASS_ARRAY_BUFFER);
    if (!abuf)
        return JS_EXCEPTION;
    return js_bool(abuf->immutable);
}

static JSValue js_array_buffer_get_byteLength(JSContext *ctx,
                                              JSValueConst this_val,
                                              int class_id)
{
    JSArrayBuffer *abuf = JS_GetOpaque2(ctx, this_val, class_id);
    if (!abuf)
        return JS_EXCEPTION;
    /* return 0 if detached */
    return js_uint32(abuf->byte_length);
}

static JSValue js_array_buffer_get_maxByteLength(JSContext *ctx,
                                                 JSValueConst this_val,
                                                 int class_id)
{
    JSArrayBuffer *abuf = JS_GetOpaque2(ctx, this_val, class_id);
    if (!abuf)
        return JS_EXCEPTION;
    if (array_buffer_is_resizable(abuf))
        return js_uint32(abuf->max_byte_length);
    return js_uint32(abuf->byte_length);
}

static JSValue js_array_buffer_get_resizable(JSContext *ctx,
                                             JSValueConst this_val,
                                             int class_id)
{
    JSArrayBuffer *abuf = JS_GetOpaque2(ctx, this_val, class_id);
    if (!abuf)
        return JS_EXCEPTION;
    return js_bool(array_buffer_is_resizable(abuf));
}

void JS_DetachArrayBuffer(JSContext *ctx, JSValueConst obj)
{
    JSArrayBuffer *abuf = JS_GetOpaque(obj, JS_CLASS_ARRAY_BUFFER);
    struct list_head *el;

    if (!abuf || abuf->detached)
        return;
    if (abuf->realloc_func) {
        abuf->realloc_func(ctx->rt, abuf->opaque, abuf->data, 0);
        /* The backing data has been released. Do not release it again when
           the detached ArrayBuffer object is later finalized. */
        abuf->realloc_func = NULL;
        abuf->opaque = NULL;
    }
    abuf->data = NULL;
    abuf->byte_length = 0;
    abuf->detached = true;

    list_for_each(el, &abuf->array_list) {
        JSTypedArray *ta;
        JSObject *p;

        ta = list_entry(el, JSTypedArray, link);
        p = ta->obj;
        /* Note: the typed array length and offset fields are not modified */
        if (p->class_id != JS_CLASS_DATAVIEW) {
            p->u.array.count = 0;
            p->u.array.u.ptr = NULL;
        }
    }
}

int JS_IsImmutableArrayBuffer(JSValueConst obj)
{
    JSArrayBuffer *abuf = JS_GetOpaque(obj, JS_CLASS_ARRAY_BUFFER);
    if (!abuf)
        return -1;
    return abuf->immutable;
}

int JS_SetImmutableArrayBuffer(JSValueConst obj, bool immutable)
{
    JSArrayBuffer *abuf = JS_GetOpaque(obj, JS_CLASS_ARRAY_BUFFER);
    if (!abuf)
        return -1;
    abuf->immutable = immutable;
    return 0;
}

/* get an ArrayBuffer or SharedArrayBuffer */
static JSArrayBuffer *js_get_array_buffer(JSContext *ctx, JSValueConst obj)
{
    JSObject *p;
    if (JS_VALUE_GET_TAG(obj) != JS_TAG_OBJECT)
        goto fail;
    p = JS_VALUE_GET_OBJ(obj);
    if (p->class_id != JS_CLASS_ARRAY_BUFFER &&
        p->class_id != JS_CLASS_SHARED_ARRAY_BUFFER) {
    fail:
        JS_ThrowTypeErrorInvalidClass(ctx, JS_CLASS_ARRAY_BUFFER);
        return NULL;
    }
    return p->u.array_buffer;
}

/* return NULL if exception. WARNING: any JS call can detach the
   buffer and render the returned pointer invalid */
uint8_t *JS_GetArrayBuffer(JSContext *ctx, size_t *psize, JSValueConst obj)
{
    JSArrayBuffer *abuf = js_get_array_buffer(ctx, obj);
    if (!abuf)
        goto fail;
    if (abuf->detached) {
        JS_ThrowTypeErrorDetachedArrayBuffer(ctx);
        goto fail;
    }
    *psize = abuf->byte_length;
    return abuf->data;
 fail:
    *psize = 0;
    return NULL;
}

static bool array_buffer_is_resizable(const JSArrayBuffer *abuf)
{
    return abuf->max_byte_length >= 0;
}

static void js_array_buffer_update_typed_arrays(JSArrayBuffer *abuf)
{
    uint32_t size_log2, size_elem;
    struct list_head *el;
    JSTypedArray *ta;
    JSObject *p;
    uint8_t *data;
    int64_t len;

    len = abuf->byte_length;
    data = abuf->data;
    list_for_each(el, &abuf->array_list) {
        ta = list_entry(el, JSTypedArray, link);
        p = ta->obj;
        if (p->class_id == JS_CLASS_DATAVIEW) {
            if (ta->track_rab && ta->offset < len)
                ta->length = len - ta->offset;
            continue;
        }
        p->u.array.count = 0;
        p->u.array.u.ptr = NULL;
        size_log2 = typed_array_size_log2(p->class_id);
        size_elem = 1 << size_log2;
        if (ta->track_rab) {
            if (len >= (int64_t)ta->offset + size_elem) {
                p->u.array.count = (len - ta->offset) >> size_log2;
                p->u.array.u.ptr = &data[ta->offset];
            }
        } else {
            if (len >= (int64_t)ta->offset + ta->length) {
                p->u.array.count = ta->length >> size_log2;
                p->u.array.u.ptr = &data[ta->offset];
            }
        }
    }
}

enum {
    JS_ARRAY_BUFFER_TRANSFER,
    JS_ARRAY_BUFFER_TRANSFER_TO_IMMUTABLE,
    JS_ARRAY_BUFFER_TRANSFER_TO_FIXED_LENGTH,
};

// ES #sec-arraybuffer.prototype.transfer
static JSValue js_array_buffer_transfer(JSContext *ctx, JSValueConst this_val,
                                        int argc, JSValueConst *argv, int magic)
{
    JSArrayBuffer *abuf;
    uint64_t new_len, old_len, max_len, *pmax_len;
    uint8_t *bs, *new_bs;
    JSReallocArrayBufferDataFunc *realloc_func;
    void *opaque;
    JSValue ret;

    abuf = JS_GetOpaque2(ctx, this_val, JS_CLASS_ARRAY_BUFFER);
    if (!abuf)
        return JS_EXCEPTION;
    if (abuf->shared)
        return JS_ThrowTypeError(ctx, "cannot transfer a SharedArrayBuffer");
    // Spec (ArrayBufferCopyAndDetach): the newLength argument must be
    // coerced (its valueOf observed) before the buffer's detachability /
    // immutability is checked, so side effects of coercion are visible.
    if (argc < 1 || JS_IsUndefined(argv[0]))
        new_len = abuf->byte_length;
    else if (JS_ToIndex(ctx, &new_len, argv[0]))
        return JS_EXCEPTION;
    if (abuf->immutable)
        return JS_ThrowTypeErrorImmutableArrayBuffer(ctx);
    if (abuf->detached)
        return JS_ThrowTypeErrorDetachedArrayBuffer(ctx);
    pmax_len = NULL;
    if (magic == JS_ARRAY_BUFFER_TRANSFER) {
        if (array_buffer_is_resizable(abuf)) { // carry over maxByteLength
            max_len = abuf->max_byte_length;
            if (new_len > max_len)
                return JS_ThrowTypeError(ctx, "invalid array buffer length");
            pmax_len = &max_len;
        }
    }
    /* create an empty AB */
    if (new_len == 0) {
        JS_DetachArrayBuffer(ctx, this_val);
        ret = js_array_buffer_constructor2(ctx, JS_UNDEFINED, 0, pmax_len,
                                           JS_CLASS_ARRAY_BUFFER);
        goto fini;
    }
    bs = abuf->data;
    old_len = abuf->byte_length;
    realloc_func = abuf->realloc_func;
    opaque = abuf->opaque;
    /* if length mismatch, realloc. Otherwise, use the same backing buffer. */
    if (new_len != old_len) {
        if (!realloc_func)
            return JS_ThrowTypeError(ctx, "array buffer is not resizable");
        /* XXX: we are currently limited to 2 GB; check before reallocating,
           new_len does not necessarily fit in a size_t */
        if (new_len > INT32_MAX)
            return JS_ThrowRangeError(ctx, "invalid array buffer length");
        new_bs = realloc_func(ctx->rt, opaque, bs, new_len);
        if (!new_bs)
            return JS_ThrowOutOfMemory(ctx);
        bs = new_bs;
        if (new_len > old_len)
            memset(bs + old_len, 0, new_len - old_len);
    }
    /* neuter the source */
    abuf->data = NULL;
    abuf->byte_length = 0;
    abuf->detached = true;
    abuf->realloc_func = NULL;
    abuf->opaque = NULL;
    js_array_buffer_update_typed_arrays(abuf);
    ret = js_array_buffer_constructor3(ctx, JS_UNDEFINED, new_len, pmax_len,
                                       JS_CLASS_ARRAY_BUFFER, bs,
                                       realloc_func, opaque,
                                       /*alloc_flag*/false);
fini:
    if (magic == JS_ARRAY_BUFFER_TRANSFER_TO_IMMUTABLE) {
        if (JS_IsException(ret))
            return JS_EXCEPTION;
        abuf = JS_GetOpaque2(ctx, ret, JS_CLASS_ARRAY_BUFFER);
        if (!abuf)
            return JS_EXCEPTION;
        abuf->immutable = true;
    }
    return ret;
}

static JSValue js_array_buffer_resize(JSContext *ctx, JSValueConst this_val,
                                      int argc, JSValueConst *argv, int class_id)
{
    JSArrayBuffer *abuf;
    uint8_t *data;
    int64_t len;

    abuf = JS_GetOpaque2(ctx, this_val, class_id);
    if (!abuf)
        return JS_EXCEPTION;
    if (abuf->immutable)
        return JS_ThrowTypeErrorImmutableArrayBuffer(ctx);
    if (JS_ToInt64(ctx, &len, argv[0]))
        return JS_EXCEPTION;
    if (abuf->detached)
        return JS_ThrowTypeErrorDetachedArrayBuffer(ctx);
    if (!array_buffer_is_resizable(abuf))
        return JS_ThrowTypeError(ctx, "array buffer is not resizable");
    if (len < 0 || len > abuf->max_byte_length) {
    bad_length:
        return JS_ThrowRangeError(ctx, "invalid array buffer length");
    }
    // SABs can only grow and we don't need to realloc because
    // js_array_buffer_constructor3 commits all memory upfront;
    // regular RABs are resizable both ways and realloc
    if (abuf->shared) {
        if (len < abuf->byte_length)
            goto bad_length;
        // Note this is off-spec; there's supposed to be a single atomic
        // |byteLength| property that's shared across SABs but we store
        // it per SAB instead. That means when thread A calls sab.grow(2)
        // at time t0, and thread B calls sab.grow(1) at time t1, we don't
        // throw a TypeError in thread B as the spec says we should,
        // instead both threads get their own view of the backing memory,
        // 2 bytes big in A, and 1 byte big in B
        abuf->byte_length = len;
    } else {
        // the ArrayBuffer cannot be resizable without a way to resize it,
        // js_array_buffer_constructor3 rejects that combination
        assert(abuf->realloc_func);
        data = abuf->realloc_func(ctx->rt, abuf->opaque, abuf->data,
                                  max_int(len, 1));
        if (!data)
            return JS_ThrowOutOfMemory(ctx);
        if (len > abuf->byte_length)
            memset(&data[abuf->byte_length], 0, len - abuf->byte_length);
        abuf->byte_length = len;
        abuf->data = data;
    }
    js_array_buffer_update_typed_arrays(abuf);
    return JS_UNDEFINED;
}

static JSValue js_array_buffer_slice(JSContext *ctx,
                                     JSValueConst this_val,
                                     int argc, JSValueConst *argv, int magic)
{
    JSArrayBuffer *abuf, *new_abuf;
    int64_t len, start, end, new_len;
    JSValue ctor, new_obj;
    bool immutable;
    int class_id;

    immutable = magic & 1;
    class_id = magic >> 1;
    abuf = JS_GetOpaque2(ctx, this_val, class_id);
    if (!abuf)
        return JS_EXCEPTION;
    if (abuf->detached)
        return JS_ThrowTypeErrorDetachedArrayBuffer(ctx);
    if (abuf->immutable)
        return JS_ThrowTypeErrorImmutableArrayBuffer(ctx);
    len = abuf->byte_length;

    if (JS_ToInt64Clamp(ctx, &start, argv[0], 0, len, len))
        return JS_EXCEPTION;

    end = len;
    if (!JS_IsUndefined(argv[1])) {
        if (JS_ToInt64Clamp(ctx, &end, argv[1], 0, len, len))
            return JS_EXCEPTION;
    }
    new_len = max_int64(end - start, 0);
    // note: difference between slice and sliceToImmutable is that the
    // latter does not have this step:
    //        1. Let _ctor_ be ? SpeciesConstructor(_O_, %ArrayBuffer%)
    ctor = JS_UNDEFINED;
    if (!immutable) {
        ctor = JS_SpeciesConstructor(ctx, this_val, JS_UNDEFINED);
        if (JS_IsException(ctor))
            return ctor;
    }
    if (JS_IsUndefined(ctor)) {
        new_obj = js_array_buffer_constructor2(ctx, JS_UNDEFINED, new_len,
                                               NULL, class_id);
    } else {
        JSValue args[1];
        args[0] = js_int64(new_len);
        new_obj = JS_CallConstructor(ctx, ctor, 1, vc(args));
        JS_FreeValue(ctx, ctor);
        JS_FreeValue(ctx, args[0]);
    }
    if (JS_IsException(new_obj))
        return new_obj;
    new_abuf = JS_GetOpaque2(ctx, new_obj, class_id);
    if (!new_abuf)
        goto fail;
    if (new_abuf->immutable) {
        JS_ThrowTypeErrorImmutableArrayBuffer(ctx);
        goto fail;
    }
    if (js_same_value(ctx, new_obj, this_val)) {
        JS_ThrowTypeError(ctx, "cannot use identical ArrayBuffer");
        goto fail;
    }
    if (new_abuf->detached) {
        JS_ThrowTypeErrorDetachedArrayBuffer(ctx);
        goto fail;
    }
    if (new_abuf->byte_length < new_len) {
        JS_ThrowTypeError(ctx, "new ArrayBuffer is too small");
        goto fail;
    }
    /* must test again because of side effects */
    if (abuf->detached) {
        JS_ThrowTypeErrorDetachedArrayBuffer(ctx);
        goto fail;
    }
    if (abuf->byte_length < start + new_len) {
        if (immutable)
            JS_ThrowRangeError(ctx, "invalid array buffer length");
        else
            JS_ThrowTypeErrorDetachedArrayBuffer(ctx);
        goto fail;
    }
    memcpy(new_abuf->data, abuf->data + start, new_len);
    new_abuf->immutable = immutable;
    return new_obj;
 fail:
    JS_FreeValue(ctx, new_obj);
    return JS_EXCEPTION;
}

static const JSCFunctionListEntry js_array_buffer_proto_funcs[] = {
    JS_CGETSET_MAGIC_DEF("byteLength", js_array_buffer_get_byteLength, NULL, JS_CLASS_ARRAY_BUFFER ),
    JS_CGETSET_MAGIC_DEF("maxByteLength", js_array_buffer_get_maxByteLength, NULL, JS_CLASS_ARRAY_BUFFER ),
    JS_CGETSET_MAGIC_DEF("resizable", js_array_buffer_get_resizable, NULL, JS_CLASS_ARRAY_BUFFER ),
    JS_CGETSET_DEF("detached", js_array_buffer_get_detached, NULL ),
    JS_CGETSET_DEF("immutable", js_array_buffer_get_immutable, NULL ),
    JS_CFUNC_MAGIC_DEF("resize", 1, js_array_buffer_resize, JS_CLASS_ARRAY_BUFFER ),
    JS_CFUNC_MAGIC_DEF("slice", 2, js_array_buffer_slice, JS_CLASS_ARRAY_BUFFER*2 + /*immutable*/0 ),
    JS_CFUNC_MAGIC_DEF("sliceToImmutable", 2, js_array_buffer_slice, JS_CLASS_ARRAY_BUFFER*2 + /*immutable*/1 ),
    JS_CFUNC_MAGIC_DEF("transfer", 0, js_array_buffer_transfer, JS_ARRAY_BUFFER_TRANSFER ),
    JS_CFUNC_MAGIC_DEF("transferToImmutable", 0, js_array_buffer_transfer, JS_ARRAY_BUFFER_TRANSFER_TO_IMMUTABLE ),
    JS_CFUNC_MAGIC_DEF("transferToFixedLength", 0, js_array_buffer_transfer, JS_ARRAY_BUFFER_TRANSFER_TO_FIXED_LENGTH ),
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "ArrayBuffer", JS_PROP_CONFIGURABLE ),
};

/* SharedArrayBuffer */

static const JSCFunctionListEntry js_shared_array_buffer_funcs[] = {
    JS_CGETSET_DEF("[Symbol.species]", js_get_this, NULL ),
};

static const JSCFunctionListEntry js_shared_array_buffer_proto_funcs[] = {
    JS_CGETSET_MAGIC_DEF("byteLength", js_array_buffer_get_byteLength, NULL, JS_CLASS_SHARED_ARRAY_BUFFER ),
    JS_CGETSET_MAGIC_DEF("maxByteLength", js_array_buffer_get_maxByteLength, NULL, JS_CLASS_SHARED_ARRAY_BUFFER ),
    JS_CGETSET_MAGIC_DEF("growable", js_array_buffer_get_resizable, NULL, JS_CLASS_SHARED_ARRAY_BUFFER ),
    JS_CFUNC_MAGIC_DEF("grow", 1, js_array_buffer_resize, JS_CLASS_SHARED_ARRAY_BUFFER ),
    JS_CFUNC_MAGIC_DEF("slice", 2, js_array_buffer_slice, JS_CLASS_SHARED_ARRAY_BUFFER*2 + /*immutable*/0 ),
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "SharedArrayBuffer", JS_PROP_CONFIGURABLE ),
};

static bool is_typed_array(JSClassID class_id)
{
    return class_id >= JS_CLASS_UINT8C_ARRAY && class_id <= JS_CLASS_FLOAT64_ARRAY;
}

// |p| must be a typed array, *not* a DataView
static bool typed_array_is_immutable(JSObject *p)
{
    JSArrayBuffer *abuf;
    JSTypedArray *ta;

    assert(is_typed_array(p->class_id));
    ta = p->u.typed_array;
    abuf = ta->buffer->u.array_buffer;
    return abuf->immutable;
}

// is the typed array detached or out of bounds relative to its RAB?
// |p| must be a typed array, *not* a DataView
static bool typed_array_is_oob(JSObject *p)
{
    JSArrayBuffer *abuf;
    JSTypedArray *ta;
    int len, size_elem;
    int64_t end;

    assert(is_typed_array(p->class_id));

    ta = p->u.typed_array;
    abuf = ta->buffer->u.array_buffer;
    if (abuf->detached)
        return true;
    len = abuf->byte_length;
    if (ta->offset > len)
        return true;
    if (ta->track_rab)
        return false;
    if (len < (int64_t)ta->offset + ta->length)
        return true;
    size_elem = 1 << typed_array_size_log2(p->class_id);
    end = (int64_t)ta->offset + (int64_t)p->u.array.count * size_elem;
    return end > len;
}

/* WARNING: 'p' must be a typed array. Works even if the array buffer
   is detached */
static uint32_t typed_array_length(JSObject *p)
{
    JSTypedArray *ta = p->u.typed_array;
    int size_log2 = typed_array_size_log2(p->class_id);
    return ta->length >> size_log2;
}

static int validate_typed_array(JSContext *ctx, JSValueConst this_val)
{
    JSObject *p;
    p = get_typed_array(ctx, this_val);
    if (!p)
        return -1;
    if (typed_array_is_oob(p)) {
        JS_ThrowTypeErrorArrayBufferOOB(ctx);
        return -1;
    }
    return 0;
}

static JSValue js_typed_array_get_length(JSContext *ctx, JSValueConst this_val)
{
    JSObject *p;
    p = get_typed_array(ctx, this_val);
    if (!p)
        return JS_EXCEPTION;
    return js_int32(p->u.array.count);
}

static JSValue js_typed_array_get_buffer(JSContext *ctx, JSValueConst this_val)
{
    JSObject *p;
    JSTypedArray *ta;
    p = get_typed_array(ctx, this_val);
    if (!p)
        return JS_EXCEPTION;
    ta = p->u.typed_array;
    return js_dup(JS_MKPTR(JS_TAG_OBJECT, ta->buffer));
}

static JSValue js_typed_array_get_byteLength(JSContext *ctx, JSValueConst this_val)
{
    uint32_t size_log2;
    JSTypedArray *ta;
    JSObject *p;

    p = get_typed_array(ctx, this_val);
    if (!p)
        return JS_EXCEPTION;
    if (typed_array_is_oob(p))
        return js_int32(0);
    ta = p->u.typed_array;
    if (!ta->track_rab)
        return js_uint32(ta->length);
    size_log2 = typed_array_size_log2(p->class_id);
    return js_int64((int64_t)p->u.array.count << size_log2);
}

static JSValue js_typed_array_get_byteOffset(JSContext *ctx, JSValueConst this_val)
{
    JSObject *p;
    JSTypedArray *ta;
    p = get_typed_array(ctx, this_val);
    if (!p)
        return JS_EXCEPTION;
    if (typed_array_is_oob(p))
        return js_int32(0);
    ta = p->u.typed_array;
    return js_uint32(ta->offset);
}

JSValue JS_NewTypedArray(JSContext *ctx, int argc, JSValueConst *argv,
                         JSTypedArrayEnum type)
{
    JSValueConst temp[3];

    if (type < JS_TYPED_ARRAY_UINT8C || type > JS_TYPED_ARRAY_FLOAT64)
        return JS_ThrowRangeError(ctx, "invalid typed array type");
    // js_typed_array_constructor makes assumptions about the length
    // of the argv vector without checking argc, so let's ensure our
    // side upholds said assumptions
    if (argc < countof(temp)) {
        temp[0] = temp[1] = temp[2] = JS_UNDEFINED;
        switch (argc) {
        case 2: temp[1] = argv[1]; // fallthru
        case 1: temp[0] = argv[0]; // fallthru
        }
        argv = temp;
    }
    return js_typed_array_constructor(ctx, JS_UNDEFINED, argc, argv,
                                      JS_CLASS_UINT8C_ARRAY + type);
}

/* Return the buffer associated to the typed array or an exception if
   it is not a typed array or if the buffer is detached. pbyte_offset,
   pbyte_length or pbytes_per_element can be NULL. */
JSValue JS_GetTypedArrayBuffer(JSContext *ctx, JSValueConst obj,
                               size_t *pbyte_offset,
                               size_t *pbyte_length,
                               size_t *pbytes_per_element)
{
    JSObject *p;
    JSTypedArray *ta;
    p = get_typed_array(ctx, obj);
    if (!p)
        return JS_EXCEPTION;
    if (typed_array_is_oob(p))
        return JS_ThrowTypeErrorArrayBufferOOB(ctx);
    ta = p->u.typed_array;
    if (pbyte_offset)
        *pbyte_offset = ta->offset;
    if (pbyte_length)
        *pbyte_length = ta->length;
    if (pbytes_per_element) {
        *pbytes_per_element = 1 << typed_array_size_log2(p->class_id);
    }
    return js_dup(JS_MKPTR(JS_TAG_OBJECT, ta->buffer));
}

/* return NULL if exception. WARNING: any JS call can detach the
   buffer and render the returned pointer invalid */
uint8_t *JS_GetUint8Array(JSContext *ctx, size_t *psize, JSValueConst obj)
{
    JSObject *p;
    JSTypedArray *ta;
    JSArrayBuffer *abuf;
    p = get_typed_array(ctx, obj);
    if (!p)
        goto fail;
    if (typed_array_is_oob(p)) {
        JS_ThrowTypeErrorArrayBufferOOB(ctx);
        goto fail;
    }
    if (p->class_id != JS_CLASS_UINT8_ARRAY && p->class_id != JS_CLASS_UINT8C_ARRAY) {
        JS_ThrowTypeError(ctx, "not a Uint8Array");
        goto fail;
    }
    ta = p->u.typed_array;
    abuf = ta->buffer->u.array_buffer;

    *psize = ta->length;
    return abuf->data + ta->offset;
 fail:
    *psize = 0;
    return NULL;
}

static JSValue js_typed_array_get_toStringTag(JSContext *ctx,
                                              JSValueConst this_val)
{
    JSObject *p;
    if (JS_VALUE_GET_TAG(this_val) != JS_TAG_OBJECT)
        return JS_UNDEFINED;
    p = JS_VALUE_GET_OBJ(this_val);
    if (!is_typed_array(p->class_id))
        return JS_UNDEFINED;
    return JS_AtomToString(ctx, ctx->rt->class_array[p->class_id].class_name);
}

static JSValue js_typed_array_set_internal(JSContext *ctx,
                                           JSValueConst dst,
                                           JSValueConst src,
                                           JSValueConst off)
{
    JSObject *p;
    JSObject *src_p;
    uint32_t i;
    int64_t dst_len, src_len, offset;
    JSValue val, src_obj = JS_UNDEFINED;

    p = get_typed_array(ctx, dst);
    if (!p)
        goto fail;
    if (typed_array_is_immutable(p)) {
        JS_ThrowTypeErrorImmutableArrayBuffer(ctx);
        goto fail;
    }
    if (JS_ToInt64Sat(ctx, &offset, off))
        goto fail;
    if (offset < 0)
        goto range_error;
    if (typed_array_is_oob(p)) {
    detached:
        JS_ThrowTypeErrorArrayBufferOOB(ctx);
        goto fail;
    }
    dst_len = p->u.array.count;
    src_obj = JS_ToObject(ctx, src);
    if (JS_IsException(src_obj))
        goto fail;
    src_p = JS_VALUE_GET_OBJ(src_obj);
    if (is_typed_array(src_p->class_id)) {
        JSTypedArray *dest_ta = p->u.typed_array;
        JSArrayBuffer *dest_abuf = dest_ta->buffer->u.array_buffer;
        JSTypedArray *src_ta = src_p->u.typed_array;
        JSArrayBuffer *src_abuf = src_ta->buffer->u.array_buffer;
        int shift = typed_array_size_log2(p->class_id);

        if (typed_array_is_oob(src_p))
            goto detached;

        src_len = src_p->u.array.count;
        if (offset > dst_len - src_len)
            goto range_error;

        /* copying between typed objects */
        if (src_p->class_id == p->class_id) {
            /* same type, use memmove */
            memmove(dest_abuf->data + dest_ta->offset + (offset << shift),
                    src_abuf->data + src_ta->offset, src_len << shift);
            goto done;
        }
        if (dest_abuf->data == src_abuf->data) {
            /* copying between the same buffer using different types of mappings
               would require a temporary buffer */
        }
        /* otherwise, default behavior is slow but correct */
    } else {
        // can change |dst| as a side effect; per spec,
        // perform the range check against its old length
        if (js_get_length64(ctx, &src_len, src_obj))
            goto fail;
        if (offset > dst_len - src_len) {
        range_error:
            JS_ThrowRangeError(ctx, "invalid array length");
            goto fail;
        }
    }
    for(i = 0; i < src_len; i++) {
        val = JS_GetPropertyUint32(ctx, src_obj, i);
        if (JS_IsException(val))
            goto fail;
        // Per spec: detaching the TA mid-iteration is allowed and should
        // not throw an exception. Because iteration over the source array is
        // observable, we cannot bail out early when the TA is first detached.
        if (typed_array_is_oob(p)) {
            JS_FreeValue(ctx, val);
        } else if (JS_SetPropertyUint32(ctx, dst, offset + i, val) < 0) {
            goto fail;
        }
    }
done:
    JS_FreeValue(ctx, src_obj);
    return JS_UNDEFINED;
fail:
    JS_FreeValue(ctx, src_obj);
    return JS_EXCEPTION;
}

static JSValue js_typed_array_at(JSContext *ctx, JSValueConst this_val,
                                 int argc, JSValueConst *argv)
{
    JSObject *p;
    int64_t idx, len;

    p = get_typed_array(ctx, this_val);
    if (!p)
        return JS_EXCEPTION;
    if (typed_array_is_oob(p))
        return JS_ThrowTypeErrorArrayBufferOOB(ctx);
    len = p->u.array.count;

    // note: can change p->u.array.count
    if (JS_ToInt64Sat(ctx, &idx, argv[0]))
        return JS_EXCEPTION;

    if (idx < 0)
        idx = len + idx;

    if (idx < 0 || idx >= len || idx >= p->u.array.count)
        return JS_UNDEFINED;

    switch (p->class_id) {
    case JS_CLASS_INT8_ARRAY:
        return js_int32(p->u.array.u.int8_ptr[idx]);
    case JS_CLASS_UINT8C_ARRAY:
    case JS_CLASS_UINT8_ARRAY:
        return js_int32(p->u.array.u.uint8_ptr[idx]);
    case JS_CLASS_INT16_ARRAY:
        return js_int32(p->u.array.u.int16_ptr[idx]);
    case JS_CLASS_UINT16_ARRAY:
        return js_int32(p->u.array.u.uint16_ptr[idx]);
    case JS_CLASS_INT32_ARRAY:
        return js_int32(p->u.array.u.int32_ptr[idx]);
    case JS_CLASS_UINT32_ARRAY:
        return js_uint32(p->u.array.u.uint32_ptr[idx]);
    case JS_CLASS_FLOAT16_ARRAY:
        return js_float64(fromfp16(p->u.array.u.fp16_ptr[idx]));
    case JS_CLASS_FLOAT32_ARRAY:
        return js_float64(p->u.array.u.float_ptr[idx]);
    case JS_CLASS_FLOAT64_ARRAY:
        return js_float64(p->u.array.u.double_ptr[idx]);
    case JS_CLASS_BIG_INT64_ARRAY:
        return JS_NewBigInt64(ctx, p->u.array.u.int64_ptr[idx]);
    case JS_CLASS_BIG_UINT64_ARRAY:
        return JS_NewBigUint64(ctx, p->u.array.u.uint64_ptr[idx]);
    }

    abort(); /* unreachable */
    return JS_UNDEFINED;
}

static JSValue js_typed_array_with(JSContext *ctx, JSValueConst this_val,
                                   int argc, JSValueConst *argv)
{
    JSValue arr, val, buffer;
    JSObject *p;
    JSTypedArray *ta;
    JSArrayBuffer *src_abuf, *abuf;
    int64_t idx;
    uint32_t len, newlen, copy_len;
    int size_log2;

    p = get_typed_array(ctx, this_val);
    if (!p)
        return JS_EXCEPTION;

    len = p->u.array.count;
    if (JS_ToInt64Sat(ctx, &idx, argv[0]))
        return JS_EXCEPTION;
    /* resolve negative index using original length (spec step 5-6) */
    if (idx < 0)
        idx = len + idx;

    if (p->class_id == JS_CLASS_BIG_INT64_ARRAY || p->class_id == JS_CLASS_BIG_UINT64_ARRAY) {
        val = JS_ToBigInt(ctx, argv[1]);
    } else {
        val = JS_ToNumber(ctx, argv[1]);
    }
    if (JS_IsException(val))
        return JS_EXCEPTION;
    /* re-validate after user code (spec step 9: IsValidIntegerIndex) */
    if (typed_array_is_oob(p)) {
        JS_FreeValue(ctx, val);
        return JS_ThrowTypeErrorArrayBufferOOB(ctx);
    }
    newlen = p->u.array.count;
    if (idx < 0 || idx >= newlen) {
        JS_FreeValue(ctx, val);
        return JS_ThrowRangeError(ctx, "invalid typed array index");
    }

    copy_len = min_uint32(len, newlen);
    size_log2 = typed_array_size_log2(p->class_id);

    /* create new typed array with original length (zero-initialized) */
    arr = js_create_from_ctor(ctx, JS_UNDEFINED, p->class_id);
    if (JS_IsException(arr)) {
        JS_FreeValue(ctx, val);
        return JS_EXCEPTION;
    }
    buffer = js_array_buffer_constructor1(ctx, JS_UNDEFINED,
                                          (uint64_t)len << size_log2,
                                          NULL);
    if (JS_IsException(buffer)) {
        JS_FreeValue(ctx, val);
        JS_FreeValue(ctx, arr);
        return JS_EXCEPTION;
    }
    if (typed_array_is_oob(p)) {
        JS_FreeValue(ctx, val);
        JS_FreeValue(ctx, buffer);
        JS_FreeValue(ctx, arr);
        return JS_ThrowTypeErrorArrayBufferOOB(ctx);
    }
    abuf = JS_GetOpaque(buffer, JS_CLASS_ARRAY_BUFFER);
    if (typed_array_init(ctx, arr, buffer, 0, len, /*track_rab*/false)) {
        JS_FreeValue(ctx, val);
        JS_FreeValue(ctx, arr);
        return JS_EXCEPTION;
    }

    /* copy min(len, newlen) elements from source; rest stays zero */
    if (copy_len > 0) {
        ta = p->u.typed_array;
        src_abuf = ta->buffer->u.array_buffer;
        memcpy(abuf->data, src_abuf->data + ta->offset,
               (size_t)copy_len << size_log2);
    }

    if (JS_SetPropertyInt64(ctx, arr, idx, val) < 0) {
        JS_FreeValue(ctx, arr);
        return JS_EXCEPTION;
    }
    return arr;
}

static JSValue js_typed_array_set(JSContext *ctx,
                                  JSValueConst this_val,
                                  int argc, JSValueConst *argv)
{
    JSValueConst offset = JS_UNDEFINED;
    if (argc > 1) {
        offset = argv[1];
    }
    return js_typed_array_set_internal(ctx, this_val, argv[0], offset);
}

static JSValue js_create_typed_array_iterator(JSContext *ctx, JSValueConst this_val,
                                              int argc, JSValueConst *argv, int magic)
{
    if (validate_typed_array(ctx, this_val))
        return JS_EXCEPTION;
    return js_create_array_iterator(ctx, this_val, argc, argv, magic);
}

static JSValue js_typed_array_create(JSContext *ctx, JSValueConst ctor,
                                     int argc, JSValueConst *argv,
                                     bool require_mutable)
{
    JSValue ret;
    int new_len;
    int64_t len;

    ret = JS_CallConstructor(ctx, ctor, argc, argv);
    if (JS_IsException(ret))
        return ret;
    /* validate the typed array */
    new_len = js_typed_array_get_length_unsafe(ctx, ret);
    if (new_len < 0)
        goto fail;
    if (require_mutable && typed_array_is_immutable(JS_VALUE_GET_OBJ(ret))) {
        JS_ThrowTypeErrorImmutableArrayBuffer(ctx);
        goto fail;
    }
    if (argc == 1) {
        /* ensure that it is large enough */
        if (JS_ToLengthFree(ctx, &len, js_dup(argv[0])))
            goto fail;
        if (new_len < len) {
            JS_ThrowTypeError(ctx, "TypedArray length is too small");
        fail:
            JS_FreeValue(ctx, ret);
            return JS_EXCEPTION;
        }
    }
    return ret;
}

// expects typed array object in argv[0] so argc *must* be > 0
static JSValue js_typed_array___speciesCreate(JSContext *ctx,
                                              JSValueConst this_val,
                                              int argc, JSValueConst *argv,
                                              bool require_mutable)
{
    JSValueConst obj;
    JSObject *p;
    JSValue ctor, ret;

    assert(argc > 0);
    obj = argv[0];
    p = get_typed_array(ctx, obj);
    if (!p)
        return JS_EXCEPTION;
    ctor = JS_SpeciesConstructor(ctx, obj, JS_UNDEFINED);
    if (JS_IsException(ctor))
        return ctor;
    argc--;
    argv++;
    if (JS_IsUndefined(ctor)) {
        ret = js_typed_array_constructor(ctx, JS_UNDEFINED, argc, argv,
                                         p->class_id);
    } else {
        ret = js_typed_array_create(ctx, ctor, argc, argv, require_mutable);
        JS_FreeValue(ctx, ctor);
    }
    return ret;
}

static JSValue js_typed_array_from(JSContext *ctx, JSValueConst this_val,
                                   int argc, JSValueConst *argv)
{
    // from(items, mapfn = void 0, this_arg = void 0)
    JSValueConst items = argv[0], mapfn, this_arg;
    JSValueConst args[2];
    JSValue stack[2];
    JSValue iter, arr, r, v, v2;
    int64_t k, len;
    int done, mapping;

    mapping = false;
    mapfn = JS_UNDEFINED;
    this_arg = JS_UNDEFINED;
    r = JS_UNDEFINED;
    arr = JS_UNDEFINED;
    stack[0] = JS_UNDEFINED;
    stack[1] = JS_UNDEFINED;

    if (argc > 1) {
        mapfn = argv[1];
        if (!JS_IsUndefined(mapfn)) {
            if (check_function(ctx, mapfn))
                goto exception;
            mapping = 1;
            if (argc > 2)
                this_arg = argv[2];
        }
    }
    iter = JS_GetProperty(ctx, items, JS_ATOM_Symbol_iterator);
    if (JS_IsException(iter))
        goto exception;
    if (!JS_IsUndefined(iter) && !JS_IsNull(iter)) {
        if (!JS_IsFunction(ctx, iter)) {
            JS_FreeValue(ctx, iter);
            JS_ThrowTypeError(ctx, "value is not iterable");
            goto exception;
        }
        arr = JS_NewArray(ctx);
        if (JS_IsException(arr)) {
            JS_FreeValue(ctx, iter);
            goto exception;
        }
        stack[0] = JS_GetIterator2(ctx, items, iter);
        JS_FreeValue(ctx, iter);
        if (JS_IsException(stack[0]))
            goto exception;
        stack[1] = JS_GetProperty(ctx, stack[0], JS_ATOM_next);
        if (JS_IsException(stack[1]))
            goto exception_close;
        for (k = 0;; k++) {
            v = JS_IteratorNext(ctx, stack[0], stack[1], 0, NULL, &done);
            if (JS_IsException(v))
                goto exception_close;
            if (done)
                break;
            if (JS_DefinePropertyValueInt64(ctx, arr, k, v, JS_PROP_C_W_E | JS_PROP_THROW) < 0)
                goto exception_close;
        }
    } else {
        arr = JS_ToObject(ctx, items);
        if (JS_IsException(arr))
            goto exception;
    }
    if (js_get_length64(ctx, &len, arr) < 0)
        goto exception;
    v = js_int64(len);
    r = js_typed_array_create(ctx, this_val, 1, vc(&v), true);
    JS_FreeValue(ctx, v);
    if (JS_IsException(r))
        goto exception;
    for(k = 0; k < len; k++) {
        v = JS_GetPropertyInt64(ctx, arr, k);
        if (JS_IsException(v))
            goto exception;
        if (mapping) {
            args[0] = v;
            args[1] = js_int32(k);
            v2 = JS_Call(ctx, mapfn, this_arg, 2, args);
            JS_FreeValue(ctx, v);
            v = v2;
            if (JS_IsException(v))
                goto exception;
        }
        if (JS_SetPropertyInt64(ctx, r, k, v) < 0)
            goto exception;
    }
    goto done;

 exception_close:
    if (!JS_IsUndefined(stack[0]))
        JS_IteratorClose(ctx, stack[0], true);
 exception:
    JS_FreeValue(ctx, r);
    r = JS_EXCEPTION;
 done:
    JS_FreeValue(ctx, arr);
    JS_FreeValue(ctx, stack[0]);
    JS_FreeValue(ctx, stack[1]);
    return r;
}

static JSValue js_typed_array_of(JSContext *ctx, JSValueConst this_val,
                                 int argc, JSValueConst *argv)
{
    JSValue v, obj;
    int i;

    v = js_int32(argc);
    obj = js_typed_array_create(ctx, this_val, 1, vc(&v), true);
    if (JS_IsException(obj))
        return obj;

    for(i = 0; i < argc; i++) {
        if (JS_SetPropertyUint32(ctx, obj, i, js_dup(argv[i])) < 0) {
            JS_FreeValue(ctx, obj);
            return JS_EXCEPTION;
        }
    }
    return obj;
}

static JSValue js_typed_array_copyWithin(JSContext *ctx, JSValueConst this_val,
                                         int argc, JSValueConst *argv)
{
    JSObject *p;
    int len, to, from, final, count, shift, space;

    p = get_typed_array(ctx, this_val);
    if (!p)
        return JS_EXCEPTION;
    if (typed_array_is_immutable(p))
        return JS_ThrowTypeErrorImmutableArrayBuffer(ctx);
    if (typed_array_is_oob(p))
        return JS_ThrowTypeErrorArrayBufferOOB(ctx);
    len = p->u.array.count;

    if (JS_ToInt32Clamp(ctx, &to, argv[0], 0, len, len))
        return JS_EXCEPTION;

    if (JS_ToInt32Clamp(ctx, &from, argv[1], 0, len, len))
        return JS_EXCEPTION;

    final = len;
    if (argc > 2 && !JS_IsUndefined(argv[2])) {
        if (JS_ToInt32Clamp(ctx, &final, argv[2], 0, len, len))
            return JS_EXCEPTION;
    }

    if (typed_array_is_oob(p))
        return JS_ThrowTypeErrorArrayBufferOOB(ctx);

    // RAB may have been resized by evil .valueOf method
    space = p->u.array.count - max_int(to, from);
    count = min_int(final - from, len - to);
    count = min_int(count, space);
    if (count > 0) {
        shift = typed_array_size_log2(p->class_id);
        memmove(p->u.array.u.uint8_ptr + (to << shift),
                p->u.array.u.uint8_ptr + (from << shift),
                count << shift);
    }
    return js_dup(this_val);
}

static JSValue js_typed_array_fill(JSContext *ctx, JSValueConst this_val,
                                   int argc, JSValueConst *argv)
{
    JSObject *p;
    int len, k, final, shift;
    uint64_t v64;

    p = get_typed_array(ctx, this_val);
    if (!p)
        return JS_EXCEPTION;
    if (typed_array_is_immutable(p))
        return JS_ThrowTypeErrorImmutableArrayBuffer(ctx);
    if (typed_array_is_oob(p))
        return JS_ThrowTypeErrorArrayBufferOOB(ctx);
    len = p->u.array.count;

    if (p->class_id == JS_CLASS_UINT8C_ARRAY) {
        int32_t v;
        if (JS_ToUint8ClampFree(ctx, &v, js_dup(argv[0])))
            return JS_EXCEPTION;
        v64 = v;
    } else if (p->class_id <= JS_CLASS_UINT32_ARRAY) {
        uint32_t v;
        if (JS_ToUint32(ctx, &v, argv[0]))
            return JS_EXCEPTION;
        v64 = v;
    } else
    if (p->class_id <= JS_CLASS_BIG_UINT64_ARRAY) {
        if (JS_ToBigInt64(ctx, (int64_t *)&v64, argv[0]))
            return JS_EXCEPTION;
    } else {
        double d;
        if (JS_ToFloat64(ctx, &d, argv[0]))
            return JS_EXCEPTION;
        if (p->class_id == JS_CLASS_FLOAT16_ARRAY) {
            v64 = tofp16(d);
        } else if (p->class_id == JS_CLASS_FLOAT32_ARRAY) {
            union {
                float f;
                uint32_t u32;
            } u;
            u.f = d;
            v64 = u.u32;
        } else {
            JSFloat64Union u;
            u.d = d;
            v64 = u.u64;
        }
    }

    k = 0;
    if (argc > 1) {
        if (JS_ToInt32Clamp(ctx, &k, argv[1], 0, len, len))
            return JS_EXCEPTION;
    }

    final = len;
    if (argc > 2 && !JS_IsUndefined(argv[2])) {
        if (JS_ToInt32Clamp(ctx, &final, argv[2], 0, len, len))
            return JS_EXCEPTION;
    }

    if (typed_array_is_oob(p))
        return JS_ThrowTypeErrorArrayBufferOOB(ctx);

    // RAB may have been resized by evil .valueOf method
    final = min_int(final, p->u.array.count);
    shift = typed_array_size_log2(p->class_id);
    switch(shift) {
    case 0:
        if (k < final) {
            memset(p->u.array.u.uint8_ptr + k, v64, final - k);
        }
        break;
    case 1:
        for(; k < final; k++) {
            p->u.array.u.uint16_ptr[k] = v64;
        }
        break;
    case 2:
        for(; k < final; k++) {
            p->u.array.u.uint32_ptr[k] = v64;
        }
        break;
    case 3:
        for(; k < final; k++) {
            p->u.array.u.uint64_ptr[k] = v64;
        }
        break;
    default:
        abort();
    }
    return js_dup(this_val);
}

static JSValue js_typed_array_find(JSContext *ctx, JSValueConst this_val,
                                   int argc, JSValueConst *argv, int mode)
{
    JSValueConst func, this_arg, args[3];
    JSValue val, index_val, res;
    int len, k, end;
    int dir;

    val = JS_UNDEFINED;
    len = js_typed_array_get_length_unsafe(ctx, this_val);
    if (len < 0)
        goto exception;

    func = argv[0];
    if (check_function(ctx, func))
        goto exception;

    this_arg = JS_UNDEFINED;
    if (argc > 1)
        this_arg = argv[1];

    k = 0;
    dir = 1;
    end = len;
    if (mode == ArrayFindLast || mode == ArrayFindLastIndex) {
        k = len - 1;
        dir = -1;
        end = -1;
    }

    for(; k != end; k += dir) {
        index_val = js_int32(k);
        val = JS_GetPropertyValue(ctx, this_val, index_val);
        if (JS_IsException(val))
            goto exception;
        args[0] = val;
        args[1] = index_val;
        args[2] = this_val;
        res = JS_Call(ctx, func, this_arg, 3, args);
        if (JS_IsException(res))
            goto exception;
        if (JS_ToBoolFree(ctx, res)) {
            if (mode == ArrayFindIndex || mode == ArrayFindLastIndex) {
                JS_FreeValue(ctx, val);
                return index_val;
            } else {
                return val;
            }
        }
        JS_FreeValue(ctx, val);
    }
    if (mode == ArrayFindIndex || mode == ArrayFindLastIndex)
        return js_int32(-1);
    else
        return JS_UNDEFINED;

exception:
    JS_FreeValue(ctx, val);
    return JS_EXCEPTION;
}

#define special_indexOf 0
#define special_lastIndexOf 1
#define special_includes -1

static JSValue js_typed_array_indexOf(JSContext *ctx, JSValueConst this_val,
                                      int argc, JSValueConst *argv, int special)
{
    JSObject *p;
    int len, tag, is_int, is_bigint, k, stop, inc, res = -1;
    int64_t v64;
    double d;
    float f;
    uint16_t hf;

    p = get_typed_array(ctx, this_val);
    if (!p)
        return JS_EXCEPTION;
    if (typed_array_is_oob(p))
        return JS_ThrowTypeErrorArrayBufferOOB(ctx);
    len = p->u.array.count;

    if (len == 0)
        goto done;

    if (special == special_lastIndexOf) {
        k = len - 1;
        if (argc > 1) {
            int64_t k1;
            if (JS_ToInt64Clamp(ctx, &k1, argv[1], -1, len - 1, len))
                goto exception;
            k = k1;
            if (k < 0)
                goto done;
        }
        stop = -1;
        inc = -1;
    } else {
        k = 0;
        if (argc > 1) {
            if (JS_ToInt32Sat(ctx, &k, argv[1]))
                goto exception;
            if (k < 0) {
                k += len;
                if (k < 0)
                    k = 0;
            } else if (k > len) {
                k = len;
            }
        }
        stop = len;
        inc = 1;
    }

    /* if the array was detached, no need to go further (but no
       exception is raised) */
    if (typed_array_is_oob(p) || len > p->u.array.count) {
        /* "includes" scans all the properties, so "undefined" can match */
        if (special == special_includes) {
            if (JS_IsUndefined(argv[0]))
                if (k < typed_array_length(p))
                    res = 0;
            goto done;
        }
        /* lastIndexOf scans downward, so when the buffer merely shrank
           during argument coercion the scan continues in the still
           valid range; the vanished indices simply cannot match */
        if (special != special_lastIndexOf || typed_array_is_oob(p))
            goto done;
    }

    // RAB may have been resized by evil .valueOf method
    len = min_int(len, p->u.array.count);
    if (len == 0)
        goto done;
    if (special == special_lastIndexOf)
        k = min_int(k, len - 1);
    else
        k = min_int(k, len);
    stop = min_int(stop, len);

    is_bigint = 0;
    is_int = 0; /* avoid warning */
    v64 = 0; /* avoid warning */
    tag = JS_VALUE_GET_NORM_TAG(argv[0]);
    if (tag == JS_TAG_INT) {
        is_int = 1;
        v64 = JS_VALUE_GET_INT(argv[0]);
        d = v64;
    } else
    if (tag == JS_TAG_FLOAT64) {
        d = JS_VALUE_GET_FLOAT64(argv[0]);
        if (d >= INT64_MIN && d < 0x1p63) {
            v64 = d;
            is_int = (v64 == d);
        }
    } else if (tag == JS_TAG_BIG_INT || tag == JS_TAG_SHORT_BIG_INT) {
        JSBigIntBuf buf1;
        JSBigInt *p1;
        int sz = (64 / JS_LIMB_BITS);
        if (tag == JS_TAG_SHORT_BIG_INT)
            p1 = js_bigint_set_short(&buf1, argv[0]);
        else
            p1 = JS_VALUE_GET_PTR(argv[0]);

        if (p->class_id == JS_CLASS_BIG_INT64_ARRAY) {
            if (p1->len > sz)
                goto done; /* does not fit an int64 : cannot be found */
        } else if (p->class_id == JS_CLASS_BIG_UINT64_ARRAY) {
            if (js_bigint_sign(p1))
                goto done; /* v < 0 */
            if (p1->len <= sz) {
                /* OK */
            } else if (p1->len == sz + 1 && p1->tab[sz] == 0) {
                /* 2^63 <= v <= 2^64-1 */
            } else {
                goto done;
            }
        } else {
            goto done;
        }
        if (JS_ToBigInt64(ctx, &v64, argv[0]))
            goto exception;
        d = 0;
        is_bigint = 1;
    } else {
        goto done;
    }

    switch (p->class_id) {
    case JS_CLASS_INT8_ARRAY:
        if (is_int && (int8_t)v64 == v64)
            goto scan8;
        break;
    case JS_CLASS_UINT8C_ARRAY:
    case JS_CLASS_UINT8_ARRAY:
        if (is_int && (uint8_t)v64 == v64) {
            const uint8_t *pv, *pp;
            uint16_t v;
        scan8:
            pv = p->u.array.u.uint8_ptr;
            v = v64;
            if (inc > 0) {
                pp = NULL;
                if (pv)
                    pp = memchr(pv + k, v, len - k);
                if (pp)
                    res = pp - pv;
            } else {
                for (; k != stop; k += inc) {
                    if (pv[k] == v) {
                        res = k;
                        break;
                    }
                }
            }
        }
        break;
    case JS_CLASS_INT16_ARRAY:
        if (is_int && (int16_t)v64 == v64)
            goto scan16;
        break;
    case JS_CLASS_UINT16_ARRAY:
        if (is_int && (uint16_t)v64 == v64) {
            const uint16_t *pv;
            uint16_t v;
        scan16:
            pv = p->u.array.u.uint16_ptr;
            v = v64;
            for (; k != stop; k += inc) {
                if (pv[k] == v) {
                    res = k;
                    break;
                }
            }
        }
        break;
    case JS_CLASS_INT32_ARRAY:
        if (is_int && (int32_t)v64 == v64)
            goto scan32;
        break;
    case JS_CLASS_UINT32_ARRAY:
        if (is_int && (uint32_t)v64 == v64) {
            const uint32_t *pv;
            uint32_t v;
        scan32:
            pv = p->u.array.u.uint32_ptr;
            v = v64;
            for (; k != stop; k += inc) {
                if (pv[k] == v) {
                    res = k;
                    break;
                }
            }
        }
        break;
    case JS_CLASS_FLOAT16_ARRAY:
        if (is_bigint)
            break;
        if (isnan(d)) {
            const uint16_t *pv = p->u.array.u.fp16_ptr;
            /* special case: indexOf returns -1, includes finds NaN */
            if (special != special_includes)
                goto done;
            for (; k != stop; k += inc) {
                if (isfp16nan(pv[k])) {
                    res = k;
                    break;
                }
            }
        } else if (d == 0) {
            // special case: includes also finds negative zero
            const uint16_t *pv = p->u.array.u.fp16_ptr;
            for (; k != stop; k += inc) {
                if (isfp16zero(pv[k])) {
                    res = k;
                    break;
                }
            }
        } else if (hf = tofp16(d), d == fromfp16(hf)) {
            const uint16_t *pv = p->u.array.u.fp16_ptr;
            for (; k != stop; k += inc) {
                if (pv[k] == hf) {
                    res = k;
                    break;
                }
            }
        }
        break;
    case JS_CLASS_FLOAT32_ARRAY:
        if (is_bigint)
            break;
        if (isnan(d)) {
            const float *pv = p->u.array.u.float_ptr;
            /* special case: indexOf returns -1, includes finds NaN */
            if (special != special_includes)
                goto done;
            for (; k != stop; k += inc) {
                if (isnan(pv[k])) {
                    res = k;
                    break;
                }
            }
        } else if ((f = (float)d) == d) {
            const float *pv = p->u.array.u.float_ptr;
            for (; k != stop; k += inc) {
                if (pv[k] == f) {
                    res = k;
                    break;
                }
            }
        }
        break;
    case JS_CLASS_FLOAT64_ARRAY:
        if (is_bigint)
            break;
        if (isnan(d)) {
            const double *pv = p->u.array.u.double_ptr;
            /* special case: indexOf returns -1, includes finds NaN */
            if (special != special_includes)
                goto done;
            for (; k != stop; k += inc) {
                if (isnan(pv[k])) {
                    res = k;
                    break;
                }
            }
        } else {
            const double *pv = p->u.array.u.double_ptr;
            for (; k != stop; k += inc) {
                if (pv[k] == d) {
                    res = k;
                    break;
                }
            }
        }
        break;
    case JS_CLASS_BIG_INT64_ARRAY:
        if (is_bigint) {
            goto scan64;
        }
        break;
    case JS_CLASS_BIG_UINT64_ARRAY:
        if (is_bigint) {
            const uint64_t *pv;
            uint64_t v;
        scan64:
            pv = p->u.array.u.uint64_ptr;
            v = v64;
            for (; k != stop; k += inc) {
                if (pv[k] == v) {
                    res = k;
                    break;
                }
            }
        }
        break;
    }

done:
    if (special == special_includes)
        return js_bool(res >= 0);
    else
        return js_int32(res);

exception:
    return JS_EXCEPTION;
}

static JSValue js_typed_array_join(JSContext *ctx, JSValueConst this_val,
                                   int argc, JSValueConst *argv, int toLocaleString)
{
    JSValue sep = JS_UNDEFINED, el;
    StringBuffer b_s, *b = &b_s;
    JSString *s = NULL;
    JSObject *p;
    int i, len, oldlen, newlen;
    int c;

    p = get_typed_array(ctx, this_val);
    if (!p)
        return JS_EXCEPTION;
    if (typed_array_is_oob(p))
        return JS_ThrowTypeErrorArrayBufferOOB(ctx);
    len = oldlen = newlen = p->u.array.count;

    c = ',';    /* default separator */
    if (!toLocaleString && argc > 0 && !JS_IsUndefined(argv[0])) {
        sep = JS_ToString(ctx, argv[0]);
        if (JS_IsException(sep))
            goto exception;
        s = JS_VALUE_GET_STRING(sep);
        if (s->len == 1 && !s->is_wide_char)
            c = str8(s)[0];
        else
            c = -1;
        // ToString(sep) can detach or resize the arraybuffer as a side effect
        newlen = p->u.array.count;
        len = min_int(len, newlen);
    }
    string_buffer_init(ctx, b, 0);

    /* XXX: optimize with direct access */
    for(i = 0; i < len; i++) {
        if (i > 0) {
            if (c >= 0) {
                if (string_buffer_putc8(b, c))
                    goto fail;
            } else {
                if (string_buffer_concat(b, s, 0, s->len))
                    goto fail;
            }
        }
        el = JS_GetPropertyUint32(ctx, this_val, i);
        /* Can return undefined for example if the typed array is detached */
        if (!JS_IsNull(el) && !JS_IsUndefined(el)) {
            if (JS_IsException(el))
                goto fail;
            if (toLocaleString) {
                el = JS_ToLocaleStringFree(ctx, el);
            }
            if (string_buffer_concat_value_free(b, el))
                goto fail;
        }
    }

    // add extra separators in case RAB was resized by evil .valueOf method
    i = max_int(1, newlen);
    for(/*empty*/; i < oldlen; i++) {
        if (c >= 0) {
            if (string_buffer_putc8(b, c))
                goto fail;
        } else {
            if (string_buffer_concat(b, s, 0, s->len))
                goto fail;
        }
    }

    JS_FreeValue(ctx, sep);
    return string_buffer_end(b);

fail:
    string_buffer_free(b);
    JS_FreeValue(ctx, sep);
exception:
    return JS_EXCEPTION;
}

static JSValue js_typed_array_reverse(JSContext *ctx, JSValueConst this_val,
                                      int argc, JSValueConst *argv)
{
    JSObject *p;
    int len;

    len = js_typed_array_get_length_unsafe(ctx, this_val);
    if (len < 0)
        return JS_EXCEPTION;
    p = JS_VALUE_GET_OBJ(this_val);
    if (typed_array_is_immutable(p))
        return JS_ThrowTypeErrorImmutableArrayBuffer(ctx);
    if (len > 0) {
        switch (typed_array_size_log2(p->class_id)) {
        case 0:
            {
                uint8_t *p1 = p->u.array.u.uint8_ptr;
                uint8_t *p2 = p1 + len - 1;
                while (p1 < p2) {
                    uint8_t v = *p1;
                    *p1++ = *p2;
                    *p2-- = v;
                }
            }
            break;
        case 1:
            {
                uint16_t *p1 = p->u.array.u.uint16_ptr;
                uint16_t *p2 = p1 + len - 1;
                while (p1 < p2) {
                    uint16_t v = *p1;
                    *p1++ = *p2;
                    *p2-- = v;
                }
            }
            break;
        case 2:
            {
                uint32_t *p1 = p->u.array.u.uint32_ptr;
                uint32_t *p2 = p1 + len - 1;
                while (p1 < p2) {
                    uint32_t v = *p1;
                    *p1++ = *p2;
                    *p2-- = v;
                }
            }
            break;
        case 3:
            {
                uint64_t *p1 = p->u.array.u.uint64_ptr;
                uint64_t *p2 = p1 + len - 1;
                while (p1 < p2) {
                    uint64_t v = *p1;
                    *p1++ = *p2;
                    *p2-- = v;
                }
            }
            break;
        default:
            abort();
        }
    }
    return js_dup(this_val);
}

static JSValue js_typed_array_toReversed(JSContext *ctx, JSValueConst this_val,
                                         int argc, JSValueConst *argv)
{
    JSValue arr, ret;
    JSObject *p;

    p = get_typed_array(ctx, this_val);
    if (!p)
        return JS_EXCEPTION;
    arr = js_typed_array_constructor_ta(ctx, JS_UNDEFINED, this_val,
                                        p->class_id, p->u.array.count);
    if (JS_IsException(arr))
        return JS_EXCEPTION;
    ret = js_typed_array_reverse(ctx, arr, argc, argv);
    JS_FreeValue(ctx, arr);
    return ret;
}

static JSValue js_typed_array_slice(JSContext *ctx, JSValueConst this_val,
                                    int argc, JSValueConst *argv)
{
    JSValueConst args[2];
    JSValue arr, val;
    JSObject *p, *p1;
    int n, len, start, final, count, shift, space;

    arr = JS_UNDEFINED;
    p = get_typed_array(ctx, this_val);
    if (!p)
        return JS_EXCEPTION;
    if (typed_array_is_oob(p))
        return JS_ThrowTypeErrorArrayBufferOOB(ctx);
    len = p->u.array.count;

    if (JS_ToInt32Clamp(ctx, &start, argv[0], 0, len, len))
        goto exception;
    final = len;
    if (!JS_IsUndefined(argv[1])) {
        if (JS_ToInt32Clamp(ctx, &final, argv[1], 0, len, len))
            goto exception;
    }
    count = max_int(final - start, 0);

    args[0] = this_val;
    args[1] = js_int32(count);
    arr = js_typed_array___speciesCreate(ctx, JS_UNDEFINED, 2, args, true);
    if (JS_IsException(arr))
        goto exception;

    if (count > 0) {
        if (validate_typed_array(ctx, this_val)
        ||  validate_typed_array(ctx, arr))
            goto exception;

        if (len != p->u.array.count)
            goto slow_path;

        p1 = get_typed_array(ctx, arr);
        if (p1 != NULL && p->class_id == p1->class_id &&
            typed_array_length(p1) >= count &&
            typed_array_length(p) >= start + count) {
            uint8_t *src, *dst;
            int nbytes;
            shift = typed_array_size_log2(p->class_id);
            src = p->u.array.u.uint8_ptr + (start << shift);
            dst = p1->u.array.u.uint8_ptr;
            nbytes = count << shift;
            if (dst > src && dst < src + nbytes) {
                /* per spec (step 14.g) the copy is performed byte by byte
                   in increasing order, observable when the species
                   constructor returns a view over the same buffer that
                   overlaps the source ahead of it */
                for (n = 0; n < nbytes; n++)
                    dst[n] = src[n];
            } else {
                memmove(dst, src, nbytes);
            }
        } else {
        slow_path:
            space = max_int(0, p->u.array.count - start);
            count = min_int(count, space);
            for (n = 0; n < count; n++) {
                val = JS_GetPropertyValue(ctx, this_val, js_int32(start + n));
                if (JS_IsException(val))
                    goto exception;
                if (JS_SetPropertyValue(ctx, arr, js_int32(n), val,
                                        JS_PROP_THROW) < 0)
                    goto exception;
            }
        }
    }
    return arr;

 exception:
    JS_FreeValue(ctx, arr);
    return JS_EXCEPTION;
}

static JSValue js_typed_array_subarray(JSContext *ctx, JSValueConst this_val,
                                       int argc, JSValueConst *argv)
{
    JSTypedArray *ta;
    JSValueConst args[4];
    JSValue arr, ta_buffer;
    JSObject *p;
    int len, start, final, count, shift, offset, nargs;

    p = get_typed_array(ctx, this_val);
    if (!p)
        goto exception;
    len = p->u.array.count;
    if (JS_ToInt32Clamp(ctx, &start, argv[0], 0, len, len))
        goto exception;
    final = len;
    if (!JS_IsUndefined(argv[1])) {
        if (JS_ToInt32Clamp(ctx, &final, argv[1], 0, len, len))
            goto exception;
    }
    count = max_int(final - start, 0);
    ta = p->u.typed_array;
    shift = typed_array_size_log2(p->class_id);
    /* per spec, read the [[ByteOffset]] slot directly: it keeps its value
       even when the buffer was detached or resized by the argument
       coercions above; validation is left to the constructor called by
       TypedArraySpeciesCreate */
    offset = ta->offset + (start << shift);
    ta_buffer = js_typed_array_get_buffer(ctx, this_val);
    if (JS_IsException(ta_buffer))
        goto exception;
    args[0] = this_val;
    args[1] = safe_const(ta_buffer);
    args[2] = safe_const(js_int32(offset));
    args[3] = safe_const(js_int32(count));
    // result is length-tracking if source TA is and no explicit end is given;
    // the constructor is then called without a length argument
    if (ta->track_rab && JS_IsUndefined(argv[1]))
        nargs = 3;
    else
        nargs = 4;
    arr = js_typed_array___speciesCreate(ctx, JS_UNDEFINED, nargs, args, false);
    JS_FreeValue(ctx, ta_buffer);
    return arr;
 exception:
    return JS_EXCEPTION;
}

/* TypedArray.prototype.sort */

static int js_cmp_doubles(double x, double y)
{
    if (isnan(x))    return isnan(y) ? 0 : +1;
    if (isnan(y))    return -1;
    if (x < y)       return -1;
    if (x > y)       return 1;
    if (x != 0)      return 0;
    if (signbit(x))  return signbit(y) ? 0 : -1;
    else             return signbit(y) ? 1 : 0;
}

static int js_TA_cmp_int8(const void *a, const void *b, void *opaque) {
    return *(const int8_t *)a - *(const int8_t *)b;
}

static int js_TA_cmp_uint8(const void *a, const void *b, void *opaque) {
    return *(const uint8_t *)a - *(const uint8_t *)b;
}

static int js_TA_cmp_int16(const void *a, const void *b, void *opaque) {
    return *(const int16_t *)a - *(const int16_t *)b;
}

static int js_TA_cmp_uint16(const void *a, const void *b, void *opaque) {
    return *(const uint16_t *)a - *(const uint16_t *)b;
}

static int js_TA_cmp_int32(const void *a, const void *b, void *opaque) {
    int32_t x = *(const int32_t *)a;
    int32_t y = *(const int32_t *)b;
    return (y < x) - (y > x);
}

static int js_TA_cmp_uint32(const void *a, const void *b, void *opaque) {
    uint32_t x = *(const uint32_t *)a;
    uint32_t y = *(const uint32_t *)b;
    return (y < x) - (y > x);
}

static int js_TA_cmp_int64(const void *a, const void *b, void *opaque) {
    int64_t x = *(const int64_t *)a;
    int64_t y = *(const int64_t *)b;
    return (y < x) - (y > x);
}

static int js_TA_cmp_uint64(const void *a, const void *b, void *opaque) {
    uint64_t x = *(const uint64_t *)a;
    uint64_t y = *(const uint64_t *)b;
    return (y < x) - (y > x);
}

static int js_TA_cmp_float16(const void *a, const void *b, void *opaque) {
    return js_cmp_doubles(fromfp16(*(const uint16_t *)a),
                          fromfp16(*(const uint16_t *)b));
}

static int js_TA_cmp_float32(const void *a, const void *b, void *opaque) {
    return js_cmp_doubles(*(const float *)a, *(const float *)b);
}

static int js_TA_cmp_float64(const void *a, const void *b, void *opaque) {
    return js_cmp_doubles(*(const double *)a, *(const double *)b);
}

static JSValue js_TA_get_int8(JSContext *ctx, const void *a) {
    return js_int32(*(const int8_t *)a);
}

static JSValue js_TA_get_uint8(JSContext *ctx, const void *a) {
    return js_int32(*(const uint8_t *)a);
}

static JSValue js_TA_get_int16(JSContext *ctx, const void *a) {
    return js_int32(*(const int16_t *)a);
}

static JSValue js_TA_get_uint16(JSContext *ctx, const void *a) {
    return js_int32(*(const uint16_t *)a);
}

static JSValue js_TA_get_int32(JSContext *ctx, const void *a) {
    return js_int32(*(const int32_t *)a);
}

static JSValue js_TA_get_uint32(JSContext *ctx, const void *a) {
    return js_uint32(*(const uint32_t *)a);
}

static JSValue js_TA_get_int64(JSContext *ctx, const void *a) {
    return JS_NewBigInt64(ctx, *(int64_t *)a);
}

static JSValue js_TA_get_uint64(JSContext *ctx, const void *a) {
    return JS_NewBigUint64(ctx, *(uint64_t *)a);
}

static JSValue js_TA_get_float16(JSContext *ctx, const void *a) {
    return js_float64(fromfp16(*(const uint16_t *)a));
}

static JSValue js_TA_get_float32(JSContext *ctx, const void *a) {
    return js_float64(*(const float *)a);
}

static JSValue js_TA_get_float64(JSContext *ctx, const void *a) {
    return js_float64(*(const double *)a);
}

struct TA_sort_context {
    JSContext *ctx;
    int exception;
    JSValueConst arr;
    JSValueConst cmp;
    JSValue (*getfun)(JSContext *ctx, const void *a);
    int elt_size;
};

static int js_TA_cmp_generic(const void *a, const void *b, void *opaque) {
    struct TA_sort_context *psc = opaque;
    JSContext *ctx = psc->ctx;
    uint32_t a_idx, b_idx;
    JSValue argv[2];
    JSValue res;
    JSObject *p;
    int cmp;

    p = JS_VALUE_GET_OBJ(psc->arr);
    if (typed_array_is_oob(p))
        return 0;

    cmp = 0;
    if (!psc->exception) {
        a_idx = *(uint32_t *)a;
        b_idx = *(uint32_t *)b;
        if (a_idx >= p->u.array.count || b_idx >= p->u.array.count)
            return 0;
        argv[0] = psc->getfun(ctx, (char *)p->u.array.u.ptr +
                              a_idx * (size_t)psc->elt_size);
        argv[1] = psc->getfun(ctx, (char *)p->u.array.u.ptr +
                              b_idx * (size_t)(psc->elt_size));
        res = JS_Call(ctx, psc->cmp, JS_UNDEFINED, 2, vc(argv));
        if (JS_IsException(res)) {
            psc->exception = 1;
            goto done;
        }
        if (JS_VALUE_GET_TAG(res) == JS_TAG_INT) {
            int val = JS_VALUE_GET_INT(res);
            cmp = (val > 0) - (val < 0);
        } else {
            double val;
            if (JS_ToFloat64Free(ctx, &val, res) < 0) {
                psc->exception = 1;
                goto done;
            } else {
                cmp = (val > 0) - (val < 0);
            }
        }
        if (cmp == 0) {
            /* make sort stable: compare array offsets */
            cmp = (a_idx > b_idx) - (a_idx < b_idx);
        }
    done:
        JS_FreeValue(ctx, argv[0]);
        JS_FreeValue(ctx, argv[1]);
    }
    return cmp;
}

static JSValue js_typed_array_sort(JSContext *ctx, JSValueConst this_val,
                                   int argc, JSValueConst *argv)
{
    JSObject *p;
    int len;
    size_t elt_size;
    struct TA_sort_context tsc;
    int (*cmpfun)(const void *a, const void *b, void *opaque);

    p = get_typed_array(ctx, this_val);
    if (!p)
        return JS_EXCEPTION;
    if (typed_array_is_immutable(p))
        return JS_ThrowTypeErrorImmutableArrayBuffer(ctx);
    if (typed_array_is_oob(p))
        return JS_ThrowTypeErrorArrayBufferOOB(ctx);

    tsc.ctx = ctx;
    tsc.exception = 0;
    tsc.arr = this_val;
    tsc.cmp = argv[0];

    if (!JS_IsUndefined(tsc.cmp) && check_function(ctx, tsc.cmp))
        return JS_EXCEPTION;

    len = p->u.array.count;
    if (len > 1) {
        switch (p->class_id) {
        case JS_CLASS_INT8_ARRAY:
            tsc.getfun = js_TA_get_int8;
            cmpfun = js_TA_cmp_int8;
            break;
        case JS_CLASS_UINT8C_ARRAY:
        case JS_CLASS_UINT8_ARRAY:
            tsc.getfun = js_TA_get_uint8;
            cmpfun = js_TA_cmp_uint8;
            break;
        case JS_CLASS_INT16_ARRAY:
            tsc.getfun = js_TA_get_int16;
            cmpfun = js_TA_cmp_int16;
            break;
        case JS_CLASS_UINT16_ARRAY:
            tsc.getfun = js_TA_get_uint16;
            cmpfun = js_TA_cmp_uint16;
            break;
        case JS_CLASS_INT32_ARRAY:
            tsc.getfun = js_TA_get_int32;
            cmpfun = js_TA_cmp_int32;
            break;
        case JS_CLASS_UINT32_ARRAY:
            tsc.getfun = js_TA_get_uint32;
            cmpfun = js_TA_cmp_uint32;
            break;
        case JS_CLASS_BIG_INT64_ARRAY:
            tsc.getfun = js_TA_get_int64;
            cmpfun = js_TA_cmp_int64;
            break;
        case JS_CLASS_BIG_UINT64_ARRAY:
            tsc.getfun = js_TA_get_uint64;
            cmpfun = js_TA_cmp_uint64;
            break;
        case JS_CLASS_FLOAT16_ARRAY:
            tsc.getfun = js_TA_get_float16;
            cmpfun = js_TA_cmp_float16;
            break;
        case JS_CLASS_FLOAT32_ARRAY:
            tsc.getfun = js_TA_get_float32;
            cmpfun = js_TA_cmp_float32;
            break;
        case JS_CLASS_FLOAT64_ARRAY:
            tsc.getfun = js_TA_get_float64;
            cmpfun = js_TA_cmp_float64;
            break;
        default:
            abort();
        }
        elt_size = 1 << typed_array_size_log2(p->class_id);
        if (!JS_IsUndefined(tsc.cmp)) {
            uint32_t *array_idx;
            void *array_tmp;
            size_t i, j;

            /* XXX: a stable sort would use less memory */
            array_idx = js_calloc(ctx, len, sizeof(array_idx[0]));
            if (!array_idx)
                return JS_EXCEPTION;
            for(i = 0; i < len; i++)
                array_idx[i] = i;
            tsc.elt_size = elt_size;
            rqsort(array_idx, len, sizeof(array_idx[0]),
                   js_TA_cmp_generic, &tsc);
            if (tsc.exception)
                goto fail;
            // per spec: typed array can be detached mid-iteration
            if (typed_array_is_oob(p))
                goto done;
            len = min_int(len, p->u.array.count);
            if (len == 0)
                goto done;
            array_tmp = js_malloc(ctx, len * elt_size);
            if (!array_tmp) {
            fail:
                js_free(ctx, array_idx);
                return JS_EXCEPTION;
            }
            memcpy(array_tmp, p->u.array.u.ptr, len * elt_size);
            switch(elt_size) {
            case 1:
                for(i = 0; i < len; i++) {
                    j = array_idx[i];
                    if (j < len)
                        p->u.array.u.uint8_ptr[i] = ((uint8_t *)array_tmp)[j];
                }
                break;
            case 2:
                for(i = 0; i < len; i++) {
                    j = array_idx[i];
                    if (j < len)
                        p->u.array.u.uint16_ptr[i] = ((uint16_t *)array_tmp)[j];
                }
                break;
            case 4:
                for(i = 0; i < len; i++) {
                    j = array_idx[i];
                    if (j < len)
                        p->u.array.u.uint32_ptr[i] = ((uint32_t *)array_tmp)[j];
                }
                break;
            case 8:
                for(i = 0; i < len; i++) {
                    j = array_idx[i];
                    if (j < len)
                        p->u.array.u.uint64_ptr[i] = ((uint64_t *)array_tmp)[j];
                }
                break;
            default:
                abort();
            }
            js_free(ctx, array_tmp);
        done:
            js_free(ctx, array_idx);
        } else {
            rqsort(p->u.array.u.ptr, len, elt_size, cmpfun, &tsc);
            if (tsc.exception)
                return JS_EXCEPTION;
        }
    }
    return js_dup(this_val);
}

static JSValue js_typed_array_toSorted(JSContext *ctx, JSValueConst this_val,
                                       int argc, JSValueConst *argv)
{
    JSValue arr, ret;
    JSObject *p;

    p = get_typed_array(ctx, this_val);
    if (!p)
        return JS_EXCEPTION;
    arr = js_typed_array_constructor_ta(ctx, JS_UNDEFINED, this_val,
                                        p->class_id, p->u.array.count);
    if (JS_IsException(arr))
        return JS_EXCEPTION;
    ret = js_typed_array_sort(ctx, arr, argc, argv);
    JS_FreeValue(ctx, arr);
    return ret;
}

static const JSCFunctionListEntry js_typed_array_base_funcs[] = {
    JS_CFUNC_DEF("from", 1, js_typed_array_from ),
    JS_CFUNC_DEF("of", 0, js_typed_array_of ),
    JS_CGETSET_DEF("[Symbol.species]", js_get_this, NULL ),
};

static const JSCFunctionListEntry js_typed_array_base_proto_funcs[] = {
    JS_CGETSET_DEF("length", js_typed_array_get_length, NULL ),
    JS_CFUNC_DEF("at", 1, js_typed_array_at ),
    JS_CFUNC_DEF("with", 2, js_typed_array_with ),
    JS_CGETSET_DEF("buffer", js_typed_array_get_buffer, NULL ),
    JS_CGETSET_DEF("byteLength", js_typed_array_get_byteLength, NULL ),
    JS_CGETSET_DEF("byteOffset", js_typed_array_get_byteOffset, NULL ),
    JS_CFUNC_DEF("set", 1, js_typed_array_set ),
    JS_CFUNC_MAGIC_DEF("values", 0, js_create_typed_array_iterator, JS_ITERATOR_KIND_VALUE ),
    JS_ALIAS_DEF("[Symbol.iterator]", "values" ),
    JS_CFUNC_MAGIC_DEF("keys", 0, js_create_typed_array_iterator, JS_ITERATOR_KIND_KEY ),
    JS_CFUNC_MAGIC_DEF("entries", 0, js_create_typed_array_iterator, JS_ITERATOR_KIND_KEY_AND_VALUE ),
    JS_CGETSET_DEF("[Symbol.toStringTag]", js_typed_array_get_toStringTag, NULL ),
    JS_CFUNC_DEF("copyWithin", 2, js_typed_array_copyWithin ),
    JS_CFUNC_MAGIC_DEF("every", 1, js_array_every, special_every | special_TA ),
    JS_CFUNC_MAGIC_DEF("some", 1, js_array_every, special_some | special_TA ),
    JS_CFUNC_MAGIC_DEF("forEach", 1, js_array_every, special_forEach | special_TA ),
    JS_CFUNC_MAGIC_DEF("map", 1, js_array_every, special_map | special_TA ),
    JS_CFUNC_MAGIC_DEF("filter", 1, js_array_every, special_filter | special_TA ),
    JS_CFUNC_MAGIC_DEF("reduce", 1, js_array_reduce, special_reduce | special_TA ),
    JS_CFUNC_MAGIC_DEF("reduceRight", 1, js_array_reduce, special_reduceRight | special_TA ),
    JS_CFUNC_DEF("fill", 1, js_typed_array_fill ),
    JS_CFUNC_MAGIC_DEF("find", 1, js_typed_array_find, ArrayFind ),
    JS_CFUNC_MAGIC_DEF("findIndex", 1, js_typed_array_find, ArrayFindIndex ),
    JS_CFUNC_MAGIC_DEF("findLast", 1, js_typed_array_find, ArrayFindLast ),
    JS_CFUNC_MAGIC_DEF("findLastIndex", 1, js_typed_array_find, ArrayFindLastIndex ),
    JS_CFUNC_DEF("reverse", 0, js_typed_array_reverse ),
    JS_CFUNC_DEF("toReversed", 0, js_typed_array_toReversed ),
    JS_CFUNC_DEF("slice", 2, js_typed_array_slice ),
    JS_CFUNC_DEF("subarray", 2, js_typed_array_subarray ),
    JS_CFUNC_DEF("sort", 1, js_typed_array_sort ),
    JS_CFUNC_DEF("toSorted", 1, js_typed_array_toSorted ),
    JS_CFUNC_MAGIC_DEF("join", 1, js_typed_array_join, 0 ),
    JS_CFUNC_MAGIC_DEF("toLocaleString", 0, js_typed_array_join, 1 ),
    JS_CFUNC_MAGIC_DEF("indexOf", 1, js_typed_array_indexOf, special_indexOf ),
    JS_CFUNC_MAGIC_DEF("lastIndexOf", 1, js_typed_array_indexOf, special_lastIndexOf ),
    JS_CFUNC_MAGIC_DEF("includes", 1, js_typed_array_indexOf, special_includes ),
    //JS_ALIAS_BASE_DEF("toString", "toString", 2 /* Array.prototype. */), @@@
};

static const JSCFunctionListEntry js_typed_array_funcs[] = {
    JS_PROP_INT32_DEF("BYTES_PER_ELEMENT", 1, 0),
    JS_PROP_INT32_DEF("BYTES_PER_ELEMENT", 2, 0),
    JS_PROP_INT32_DEF("BYTES_PER_ELEMENT", 4, 0),
    JS_PROP_INT32_DEF("BYTES_PER_ELEMENT", 8, 0),
};

static JSValue js_typed_array_base_constructor(JSContext *ctx,
                                               JSValueConst this_val,
                                               int argc, JSValueConst *argv)
{
    return JS_ThrowTypeError(ctx, "cannot be called");
}

/* 'obj' must be an allocated typed array object */
static int typed_array_init(JSContext *ctx, JSValue obj, JSValue buffer,
                            uint64_t offset, uint64_t len, bool track_rab)
{
    JSTypedArray *ta;
    JSObject *p, *pbuffer;
    JSArrayBuffer *abuf;
    int size_log2;

    p = JS_VALUE_GET_OBJ(obj);
    size_log2 = typed_array_size_log2(p->class_id);
    ta = js_malloc(ctx, sizeof(*ta));
    if (!ta) {
        JS_FreeValue(ctx, buffer);
        return -1;
    }
    pbuffer = JS_VALUE_GET_OBJ(buffer);
    abuf = pbuffer->u.array_buffer;
    ta->obj = p;
    ta->buffer = pbuffer;
    ta->offset = offset;
    ta->length = len << size_log2;
    ta->track_rab = track_rab;
    list_add_tail(&ta->link, &abuf->array_list);
    p->u.typed_array = ta;
    p->u.array.count = len;
    p->u.array.u.ptr = abuf->data + offset;
    return 0;
}


static JSValue js_array_from_iterator(JSContext *ctx, uint32_t *plen,
                                      JSValueConst obj, JSValueConst method)
{
    JSValue arr, iter, next_method = JS_UNDEFINED, val;
    int done;
    uint32_t k;

    *plen = 0;
    arr = JS_NewArray(ctx);
    if (JS_IsException(arr))
        return arr;
    iter = JS_GetIterator2(ctx, obj, method);
    if (JS_IsException(iter))
        goto fail;
    next_method = JS_GetProperty(ctx, iter, JS_ATOM_next);
    if (JS_IsException(next_method))
        goto fail;
    k = 0;
    for(;;) {
        val = JS_IteratorNext(ctx, iter, next_method, 0, NULL, &done);
        if (JS_IsException(val))
            goto fail;
        if (done)
            break;
        if (JS_CreateDataPropertyUint32(ctx, arr, k, val, JS_PROP_THROW) < 0)
            goto fail;
        k++;
    }
    JS_FreeValue(ctx, next_method);
    JS_FreeValue(ctx, iter);
    *plen = k;
    return arr;
 fail:
    JS_FreeValue(ctx, next_method);
    JS_FreeValue(ctx, iter);
    JS_FreeValue(ctx, arr);
    return JS_EXCEPTION;
}

static JSValue js_typed_array_constructor_obj(JSContext *ctx,
                                              JSValueConst new_target,
                                              JSValueConst obj,
                                              int classid)
{
    JSValue iter, ret, arr = JS_UNDEFINED, val, buffer;
    uint32_t i;
    int size_log2;
    int64_t len;

    size_log2 = typed_array_size_log2(classid);
    ret = js_create_from_ctor(ctx, new_target, classid);
    if (JS_IsException(ret))
        return JS_EXCEPTION;

    iter = JS_GetProperty(ctx, obj, JS_ATOM_Symbol_iterator);
    if (JS_IsException(iter))
        goto fail;
    if (!JS_IsUndefined(iter) && !JS_IsNull(iter)) {
        uint32_t len1;
        arr = js_array_from_iterator(ctx, &len1, obj, iter);
        JS_FreeValue(ctx, iter);
        if (JS_IsException(arr))
            goto fail;
        len = len1;
    } else {
        if (js_get_length64(ctx, &len, obj))
            goto fail;
        arr = js_dup(obj);
    }

    buffer = js_array_buffer_constructor1(ctx, JS_UNDEFINED,
                                          len << size_log2,
                                          NULL);
    if (JS_IsException(buffer))
        goto fail;
    if (typed_array_init(ctx, ret, buffer, 0, len, /*track_rab*/false))
        goto fail;

    for(i = 0; i < len; i++) {
        val = JS_GetPropertyUint32(ctx, arr, i);
        if (JS_IsException(val))
            goto fail;
        if (JS_SetPropertyUint32(ctx, ret, i, val) < 0)
            goto fail;
    }
    JS_FreeValue(ctx, arr);
    return ret;
 fail:
    JS_FreeValue(ctx, arr);
    JS_FreeValue(ctx, ret);
    return JS_EXCEPTION;
}

static JSValue js_typed_array_constructor_ta(JSContext *ctx,
                                             JSValueConst new_target,
                                             JSValueConst src_obj,
                                             int classid, uint32_t len)
{
    JSObject *p, *src_buffer;
    JSTypedArray *ta;
    JSValue obj, buffer;
    uint32_t i;
    int size_log2;
    JSArrayBuffer *src_abuf, *abuf;

    obj = js_create_from_ctor(ctx, new_target, classid);
    if (JS_IsException(obj))
        return obj;
    p = JS_VALUE_GET_OBJ(src_obj);
    if (typed_array_is_oob(p)) {
        JS_ThrowTypeErrorArrayBufferOOB(ctx);
        goto fail;
    }
    bool src_is_bigint = p->class_id == JS_CLASS_BIG_INT64_ARRAY ||
                         p->class_id == JS_CLASS_BIG_UINT64_ARRAY;
    bool dst_is_bigint = classid == JS_CLASS_BIG_INT64_ARRAY ||
                         classid == JS_CLASS_BIG_UINT64_ARRAY;
    if (src_is_bigint != dst_is_bigint) {
        JS_ThrowTypeError(ctx, "Cannot mix BigInt and other types, use explicit conversions");
        goto fail;
    }
    if (len > p->u.array.count) {
        JS_ThrowRangeError(ctx, "length out of bounds");
        goto fail;
    }
    ta = p->u.typed_array;
    src_buffer = ta->buffer;
    src_abuf = src_buffer->u.array_buffer;
    size_log2 = typed_array_size_log2(classid);
    buffer = js_array_buffer_constructor1(ctx, JS_UNDEFINED,
                                          (uint64_t)len << size_log2,
                                          NULL);
    if (JS_IsException(buffer))
        goto fail;
    /* necessary because it could have been detached */
    if (typed_array_is_oob(p)) {
        JS_FreeValue(ctx, buffer);
        JS_ThrowTypeErrorArrayBufferOOB(ctx);
        goto fail;
    }
    abuf = JS_GetOpaque(buffer, JS_CLASS_ARRAY_BUFFER);
    if (typed_array_init(ctx, obj, buffer, 0, len, /*track_rab*/false))
        goto fail;
    if (p->class_id == classid) {
        /* same type: copy the content */
        memcpy(abuf->data, src_abuf->data + ta->offset, abuf->byte_length);
    } else {
        for(i = 0; i < len; i++) {
            JSValue val;
            val = JS_GetPropertyUint32(ctx, src_obj, i);
            if (JS_IsException(val))
                goto fail;
            if (JS_SetPropertyUint32(ctx, obj, i, val) < 0)
                goto fail;
        }
    }
    return obj;
 fail:
    JS_FreeValue(ctx, obj);
    return JS_EXCEPTION;
}

static JSValue js_typed_array_constructor(JSContext *ctx,
                                          JSValueConst new_target,
                                          int argc, JSValueConst *argv,
                                          int classid)
{
    bool track_rab = false;
    JSValue buffer, obj;
    JSArrayBuffer *abuf;
    int size_log2;
    uint64_t len, offset;

    size_log2 = typed_array_size_log2(classid);
    if (JS_VALUE_GET_TAG(argv[0]) != JS_TAG_OBJECT) {
        if (JS_ToIndex(ctx, &len, argv[0]))
            return JS_EXCEPTION;
        buffer = js_array_buffer_constructor1(ctx, JS_UNDEFINED,
                                              len << size_log2,
                                              NULL);
        if (JS_IsException(buffer))
            return JS_EXCEPTION;
        offset = 0;
    } else {
        JSObject *p = JS_VALUE_GET_OBJ(argv[0]);
        if (p->class_id == JS_CLASS_ARRAY_BUFFER ||
            p->class_id == JS_CLASS_SHARED_ARRAY_BUFFER) {
            abuf = p->u.array_buffer;
            if (JS_ToIndex(ctx, &offset, argv[1]))
                return JS_EXCEPTION;
            if (abuf->detached)
                return JS_ThrowTypeErrorDetachedArrayBuffer(ctx);
            if ((offset & ((1 << size_log2) - 1)) != 0 ||
                offset > abuf->byte_length)
                return JS_ThrowRangeError(ctx, "invalid offset");
            if (JS_IsUndefined(argv[2])) {
                track_rab = array_buffer_is_resizable(abuf);
                if (!track_rab)
                    if ((abuf->byte_length & ((1 << size_log2) - 1)) != 0)
                        goto invalid_length;
                len = (abuf->byte_length - offset) >> size_log2;
            } else {
                if (JS_ToIndex(ctx, &len, argv[2]))
                    return JS_EXCEPTION;
                if (abuf->detached)
                    return JS_ThrowTypeErrorDetachedArrayBuffer(ctx);
                if ((offset + (len << size_log2)) > abuf->byte_length) {
                invalid_length:
                    return JS_ThrowRangeError(ctx, "invalid length");
                }
            }
            buffer = js_dup(argv[0]);
        } else {
            if (is_typed_array(p->class_id)) {
                return js_typed_array_constructor_ta(ctx, new_target, argv[0],
                                                     classid, p->u.array.count);
            } else {
                return js_typed_array_constructor_obj(ctx, new_target, argv[0], classid);
            }
        }
    }

    obj = js_create_from_ctor(ctx, new_target, classid);
    if (JS_IsException(obj)) {
        JS_FreeValue(ctx, buffer);
        return JS_EXCEPTION;
    }
    // Re-validate buffer after js_create_from_ctor which may have run JS code
    // that resized or detached the ArrayBuffer
    abuf = JS_VALUE_GET_OBJ(buffer)->u.array_buffer;
    if (abuf->detached) {
        JS_FreeValue(ctx, buffer);
        JS_FreeValue(ctx, obj);
        return JS_ThrowTypeErrorDetachedArrayBuffer(ctx);
    }
    if (offset > abuf->byte_length) {
        JS_FreeValue(ctx, buffer);
        JS_FreeValue(ctx, obj);
        return JS_ThrowRangeError(ctx, "invalid offset");
    }
    if (track_rab) {
        // Recalculate length for RAB-backed view
        len = (abuf->byte_length - offset) >> size_log2;
    } else if ((offset + (len << size_log2)) > abuf->byte_length) {
        JS_FreeValue(ctx, buffer);
        JS_FreeValue(ctx, obj);
        return JS_ThrowRangeError(ctx, "invalid length");
    }
    if (typed_array_init(ctx, obj, buffer, offset, len, track_rab)) {
        JS_FreeValue(ctx, obj);
        return JS_EXCEPTION;
    }
    return obj;
}

static void js_typed_array_finalizer(JSRuntime *rt, JSValueConst val)
{
    JSObject *p = JS_VALUE_GET_OBJ(val);
    JSTypedArray *ta = p->u.typed_array;
    if (ta) {
        /* during the GC the finalizers are called in an arbitrary
           order so the ArrayBuffer finalizer may have been called */
        if (ta->link.next) {
            list_del(&ta->link);
        }
        JS_FreeValueRT(rt, JS_MKPTR(JS_TAG_OBJECT, ta->buffer));
        js_free_rt(rt, ta);
    }
}

static void js_typed_array_mark(JSRuntime *rt, JSValueConst val,
                                JS_MarkFunc *mark_func)
{
    JSObject *p = JS_VALUE_GET_OBJ(val);
    JSTypedArray *ta = p->u.typed_array;
    if (ta) {
        JS_MarkValue(rt, JS_MKPTR(JS_TAG_OBJECT, ta->buffer), mark_func);
    }
}

static JSValue js_dataview_constructor(JSContext *ctx,
                                       JSValueConst new_target,
                                       int argc, JSValueConst *argv)
{
    bool recompute_len = false;
    bool track_rab = false;
    JSArrayBuffer *abuf;
    uint64_t offset;
    uint32_t len;
    JSValueConst buffer;
    JSValue obj;
    JSTypedArray *ta;
    JSObject *p;

    buffer = argv[0];
    abuf = js_get_array_buffer(ctx, buffer);
    if (!abuf)
        return JS_EXCEPTION;
    offset = 0;
    if (argc > 1) {
        if (JS_ToIndex(ctx, &offset, argv[1]))
            return JS_EXCEPTION;
    }
    if (abuf->detached)
        return JS_ThrowTypeErrorDetachedArrayBuffer(ctx);
    if (offset > abuf->byte_length)
        return JS_ThrowRangeError(ctx, "invalid byteOffset");
    len = abuf->byte_length - offset;
    if (argc > 2 && !JS_IsUndefined(argv[2])) {
        uint64_t l;
        if (JS_ToIndex(ctx, &l, argv[2]))
            return JS_EXCEPTION;
        if (l > len)
            return JS_ThrowRangeError(ctx, "invalid byteLength");
        len = l;
    } else {
        recompute_len = true;
        track_rab = array_buffer_is_resizable(abuf);
    }

    obj = js_create_from_ctor(ctx, new_target, JS_CLASS_DATAVIEW);
    if (JS_IsException(obj))
        return JS_EXCEPTION;
    if (abuf->detached) {
        /* could have been detached in js_create_from_ctor() */
        JS_ThrowTypeErrorDetachedArrayBuffer(ctx);
        goto fail;
    }
    // RAB could have been resized in js_create_from_ctor()
    if (offset > abuf->byte_length) {
        goto out_of_bound;
    } else if (recompute_len) {
        len = abuf->byte_length - offset;
    } else if (offset + len > abuf->byte_length) {
    out_of_bound:
        JS_ThrowRangeError(ctx, "invalid byteOffset or byteLength");
        goto fail;
    }
    ta = js_malloc(ctx, sizeof(*ta));
    if (!ta) {
    fail:
        JS_FreeValue(ctx, obj);
        return JS_EXCEPTION;
    }
    p = JS_VALUE_GET_OBJ(obj);
    ta->obj = p;
    ta->buffer = JS_VALUE_GET_OBJ(js_dup(buffer));
    ta->offset = offset;
    ta->length = len;
    ta->track_rab = track_rab;
    list_add_tail(&ta->link, &abuf->array_list);
    p->u.typed_array = ta;
    return obj;
}

// is the DataView out of bounds relative to its parent arraybuffer?
static bool dataview_is_oob(JSObject *p)
{
    JSArrayBuffer *abuf;
    JSTypedArray *ta;

    assert(p->class_id == JS_CLASS_DATAVIEW);
    ta = p->u.typed_array;
    abuf = ta->buffer->u.array_buffer;
    if (abuf->detached)
        return true;
    if (ta->offset > abuf->byte_length)
        return true;
    if (ta->track_rab)
        return false;
    return (int64_t)ta->offset + ta->length > abuf->byte_length;
}

static JSObject *get_dataview(JSContext *ctx, JSValueConst this_val)
{
    JSObject *p;
    if (JS_VALUE_GET_TAG(this_val) != JS_TAG_OBJECT)
        goto fail;
    p = JS_VALUE_GET_OBJ(this_val);
    if (p->class_id != JS_CLASS_DATAVIEW) {
    fail:
        JS_ThrowTypeError(ctx, "not a DataView");
        return NULL;
    }
    return p;
}

static JSValue js_dataview_get_buffer(JSContext *ctx, JSValueConst this_val)
{
    JSObject *p;
    JSTypedArray *ta;
    p = get_dataview(ctx, this_val);
    if (!p)
        return JS_EXCEPTION;
    ta = p->u.typed_array;
    return js_dup(JS_MKPTR(JS_TAG_OBJECT, ta->buffer));
}

static JSValue js_dataview_get_byteLength(JSContext *ctx, JSValueConst this_val)
{
    JSArrayBuffer *abuf;
    JSTypedArray *ta;
    JSObject *p;

    p = get_dataview(ctx, this_val);
    if (!p)
        return JS_EXCEPTION;
    if (dataview_is_oob(p))
        return JS_ThrowTypeErrorArrayBufferOOB(ctx);
    ta = p->u.typed_array;
    if (ta->track_rab) {
        abuf = ta->buffer->u.array_buffer;
        return js_uint32(abuf->byte_length - ta->offset);
    }
    return js_uint32(ta->length);
}

static JSValue js_dataview_get_byteOffset(JSContext *ctx, JSValueConst this_val)
{
    JSTypedArray *ta;
    JSObject *p;

    p = get_dataview(ctx, this_val);
    if (!p)
        return JS_EXCEPTION;
    if (dataview_is_oob(p))
        return JS_ThrowTypeErrorArrayBufferOOB(ctx);
    ta = p->u.typed_array;
    return js_uint32(ta->offset);
}

static JSValue js_dataview_getValue(JSContext *ctx,
                                    JSValueConst this_obj,
                                    int argc, JSValueConst *argv, int class_id)
{
    JSTypedArray *ta;
    JSArrayBuffer *abuf;
    bool littleEndian, is_swap;
    int size;
    uint8_t *ptr;
    uint32_t v;
    uint64_t pos;

    ta = JS_GetOpaque2(ctx, this_obj, JS_CLASS_DATAVIEW);
    if (!ta)
        return JS_EXCEPTION;
    size = 1 << typed_array_size_log2(class_id);
    if (JS_ToIndex(ctx, &pos, argv[0]))
        return JS_EXCEPTION;
    littleEndian = argc > 1 && JS_ToBool(ctx, argv[1]);
    is_swap = littleEndian ^ !is_be();
    abuf = ta->buffer->u.array_buffer;
    if (abuf->detached)
        return JS_ThrowTypeErrorDetachedArrayBuffer(ctx);
    // order matters: this check should come before the next one
    if ((pos + size) > ta->length)
        return JS_ThrowRangeError(ctx, "out of bound");
    // test262 expects a TypeError for this and V8, in its infinite wisdom,
    // throws a "detached array buffer" exception, but IMO that doesn't make
    // sense because the buffer is not in fact detached, it's still there
    if ((int64_t)ta->offset + ta->length > abuf->byte_length)
        return JS_ThrowTypeError(ctx, "out of bound");
    ptr = abuf->data + ta->offset + pos;

    switch(class_id) {
    case JS_CLASS_INT8_ARRAY:
        return js_int32(*(int8_t *)ptr);
    case JS_CLASS_UINT8_ARRAY:
        return js_int32(*(uint8_t *)ptr);
    case JS_CLASS_INT16_ARRAY:
        v = get_u16(ptr);
        if (is_swap)
            v = bswap16(v);
        return js_int32((int16_t)v);
    case JS_CLASS_UINT16_ARRAY:
        v = get_u16(ptr);
        if (is_swap)
            v = bswap16(v);
        return js_int32(v);
    case JS_CLASS_INT32_ARRAY:
        v = get_u32(ptr);
        if (is_swap)
            v = bswap32(v);
        return js_int32(v);
    case JS_CLASS_UINT32_ARRAY:
        v = get_u32(ptr);
        if (is_swap)
            v = bswap32(v);
        return js_uint32(v);
    case JS_CLASS_BIG_INT64_ARRAY:
        {
            uint64_t v;
            v = get_u64(ptr);
            if (is_swap)
                v = bswap64(v);
            return JS_NewBigInt64(ctx, v);
        }
        break;
    case JS_CLASS_BIG_UINT64_ARRAY:
        {
            uint64_t v;
            v = get_u64(ptr);
            if (is_swap)
                v = bswap64(v);
            return JS_NewBigUint64(ctx, v);
        }
        break;
    case JS_CLASS_FLOAT16_ARRAY:
        {
            uint16_t v;
            v = get_u16(ptr);
            if (is_swap)
                v = bswap16(v);
            return js_float64(fromfp16(v));
        }
    case JS_CLASS_FLOAT32_ARRAY:
        {
            union {
                float f;
                uint32_t i;
            } u;
            v = get_u32(ptr);
            if (is_swap)
                v = bswap32(v);
            u.i = v;
            return js_float64(u.f);
        }
    case JS_CLASS_FLOAT64_ARRAY:
        {
            union {
                double f;
                uint64_t i;
            } u;
            u.i = get_u64(ptr);
            if (is_swap)
                u.i = bswap64(u.i);
            return js_float64(u.f);
        }
    default:
        abort();
    }
    return JS_EXCEPTION; // pacify compiler
}

static JSValue js_dataview_setValue(JSContext *ctx,
                                    JSValueConst this_obj,
                                    int argc, JSValueConst *argv, int class_id)
{
    JSTypedArray *ta;
    JSArrayBuffer *abuf;
    bool littleEndian, is_swap;
    int size;
    uint8_t *ptr;
    uint64_t v64;
    uint32_t v;
    uint64_t pos;
    JSValueConst val;

    ta = JS_GetOpaque2(ctx, this_obj, JS_CLASS_DATAVIEW);
    if (!ta)
        return JS_EXCEPTION;
    abuf = ta->buffer->u.array_buffer;
    if (abuf->immutable)
        return JS_ThrowTypeErrorImmutableArrayBuffer(ctx);
    size = 1 << typed_array_size_log2(class_id);
    if (JS_ToIndex(ctx, &pos, argv[0]))
        return JS_EXCEPTION;
    val = argv[1];
    v = 0; /* avoid warning */
    v64 = 0; /* avoid warning */
    if (class_id <= JS_CLASS_UINT32_ARRAY) {
        if (JS_ToUint32(ctx, &v, val))
            return JS_EXCEPTION;
    } else if (class_id <= JS_CLASS_BIG_UINT64_ARRAY) {
        if (JS_ToBigInt64(ctx, (int64_t *)&v64, val))
            return JS_EXCEPTION;
    } else {
        double d;
        if (JS_ToFloat64(ctx, &d, val))
            return JS_EXCEPTION;
        if (class_id == JS_CLASS_FLOAT16_ARRAY) {
            v = tofp16(d);
        } else if (class_id == JS_CLASS_FLOAT32_ARRAY) {
            union {
                float f;
                uint32_t i;
            } u;
            u.f = d;
            v = u.i;
        } else {
            JSFloat64Union u;
            u.d = d;
            v64 = u.u64;
        }
    }
    littleEndian = argc > 2 && JS_ToBool(ctx, argv[2]);
    is_swap = littleEndian ^ !is_be();
    if (abuf->detached)
        return JS_ThrowTypeErrorDetachedArrayBuffer(ctx);
    // order matters: this check should come before the next one
    if ((pos + size) > ta->length)
        return JS_ThrowRangeError(ctx, "out of bound");
    // test262 expects a TypeError for this and V8, in its infinite wisdom,
    // throws a "detached array buffer" exception, but IMO that doesn't make
    // sense because the buffer is not in fact detached, it's still there
    if ((int64_t)ta->offset + ta->length > abuf->byte_length)
        return JS_ThrowTypeError(ctx, "out of bound");
    ptr = abuf->data + ta->offset + pos;

    switch(class_id) {
    case JS_CLASS_INT8_ARRAY:
    case JS_CLASS_UINT8_ARRAY:
        *ptr = v;
        break;
    case JS_CLASS_INT16_ARRAY:
    case JS_CLASS_UINT16_ARRAY:
    case JS_CLASS_FLOAT16_ARRAY:
        if (is_swap)
            v = bswap16(v);
        put_u16(ptr, v);
        break;
    case JS_CLASS_INT32_ARRAY:
    case JS_CLASS_UINT32_ARRAY:
    case JS_CLASS_FLOAT32_ARRAY:
        if (is_swap)
            v = bswap32(v);
        put_u32(ptr, v);
        break;
    case JS_CLASS_BIG_INT64_ARRAY:
    case JS_CLASS_BIG_UINT64_ARRAY:
    case JS_CLASS_FLOAT64_ARRAY:
        if (is_swap)
            v64 = bswap64(v64);
        put_u64(ptr, v64);
        break;
    default:
        abort();
    }
    return JS_UNDEFINED;
}

static const JSCFunctionListEntry js_dataview_proto_funcs[] = {
    JS_CGETSET_DEF("buffer", js_dataview_get_buffer, NULL ),
    JS_CGETSET_DEF("byteLength", js_dataview_get_byteLength, NULL ),
    JS_CGETSET_DEF("byteOffset", js_dataview_get_byteOffset, NULL ),
    JS_CFUNC_MAGIC_DEF("getInt8", 1, js_dataview_getValue, JS_CLASS_INT8_ARRAY ),
    JS_CFUNC_MAGIC_DEF("getUint8", 1, js_dataview_getValue, JS_CLASS_UINT8_ARRAY ),
    JS_CFUNC_MAGIC_DEF("getInt16", 1, js_dataview_getValue, JS_CLASS_INT16_ARRAY ),
    JS_CFUNC_MAGIC_DEF("getUint16", 1, js_dataview_getValue, JS_CLASS_UINT16_ARRAY ),
    JS_CFUNC_MAGIC_DEF("getInt32", 1, js_dataview_getValue, JS_CLASS_INT32_ARRAY ),
    JS_CFUNC_MAGIC_DEF("getUint32", 1, js_dataview_getValue, JS_CLASS_UINT32_ARRAY ),
    JS_CFUNC_MAGIC_DEF("getBigInt64", 1, js_dataview_getValue, JS_CLASS_BIG_INT64_ARRAY ),
    JS_CFUNC_MAGIC_DEF("getBigUint64", 1, js_dataview_getValue, JS_CLASS_BIG_UINT64_ARRAY ),
    JS_CFUNC_MAGIC_DEF("getFloat16", 1, js_dataview_getValue, JS_CLASS_FLOAT16_ARRAY ),
    JS_CFUNC_MAGIC_DEF("getFloat32", 1, js_dataview_getValue, JS_CLASS_FLOAT32_ARRAY ),
    JS_CFUNC_MAGIC_DEF("getFloat64", 1, js_dataview_getValue, JS_CLASS_FLOAT64_ARRAY ),
    JS_CFUNC_MAGIC_DEF("setInt8", 2, js_dataview_setValue, JS_CLASS_INT8_ARRAY ),
    JS_CFUNC_MAGIC_DEF("setUint8", 2, js_dataview_setValue, JS_CLASS_UINT8_ARRAY ),
    JS_CFUNC_MAGIC_DEF("setInt16", 2, js_dataview_setValue, JS_CLASS_INT16_ARRAY ),
    JS_CFUNC_MAGIC_DEF("setUint16", 2, js_dataview_setValue, JS_CLASS_UINT16_ARRAY ),
    JS_CFUNC_MAGIC_DEF("setInt32", 2, js_dataview_setValue, JS_CLASS_INT32_ARRAY ),
    JS_CFUNC_MAGIC_DEF("setUint32", 2, js_dataview_setValue, JS_CLASS_UINT32_ARRAY ),
    JS_CFUNC_MAGIC_DEF("setBigInt64", 2, js_dataview_setValue, JS_CLASS_BIG_INT64_ARRAY ),
    JS_CFUNC_MAGIC_DEF("setBigUint64", 2, js_dataview_setValue, JS_CLASS_BIG_UINT64_ARRAY ),
    JS_CFUNC_MAGIC_DEF("setFloat16", 2, js_dataview_setValue, JS_CLASS_FLOAT16_ARRAY ),
    JS_CFUNC_MAGIC_DEF("setFloat32", 2, js_dataview_setValue, JS_CLASS_FLOAT32_ARRAY ),
    JS_CFUNC_MAGIC_DEF("setFloat64", 2, js_dataview_setValue, JS_CLASS_FLOAT64_ARRAY ),
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "DataView", JS_PROP_CONFIGURABLE ),
};

static JSValue js_new_uint8array(JSContext *ctx, JSValue buffer)
{
    if (JS_IsException(buffer))
        return JS_EXCEPTION;
    JSValue obj = js_create_from_ctor(ctx, JS_UNDEFINED, JS_CLASS_UINT8_ARRAY);
    if (JS_IsException(obj)) {
        JS_FreeValue(ctx, buffer);
        return JS_EXCEPTION;
    }
    JSArrayBuffer *abuf = js_get_array_buffer(ctx, buffer);
    assert(abuf != NULL);
    if (typed_array_init(ctx, obj, buffer, 0, abuf->byte_length, /*track_rab*/false)) {
        // 'buffer' is freed on error above.
        JS_FreeValue(ctx, obj);
        return JS_EXCEPTION;
    }
    return obj;
}

JSValue JS_NewUint8Array(JSContext *ctx, uint8_t *buf, size_t len,
                         JSReallocArrayBufferDataFunc *realloc_func,
                         void *opaque, bool is_shared)
{
    JSClassID class_id =
        is_shared ? JS_CLASS_SHARED_ARRAY_BUFFER : JS_CLASS_ARRAY_BUFFER;
    JSValue buffer = js_array_buffer_constructor3(ctx, JS_UNDEFINED, len, NULL,
                                                  class_id, buf, realloc_func,
                                                  opaque, false);
    return js_new_uint8array(ctx, buffer);
}

JSValue JS_NewUint8ArrayCopy(JSContext *ctx, const uint8_t *buf, size_t len)
{
    JSValue buffer = js_array_buffer_constructor3(ctx, JS_UNDEFINED, len, NULL,
                                                  JS_CLASS_ARRAY_BUFFER,
                                                  (uint8_t *)buf,
                                                  js_array_buffer_realloc, NULL,
                                                  true);
    return js_new_uint8array(ctx, buffer);
}

int JS_GetTypedArrayType(JSValueConst obj)
{
    JSClassID class_id = JS_GetClassID(obj);
    if (is_typed_array(class_id))
        return class_id - JS_CLASS_UINT8C_ARRAY;
    else
        return -1;
}

/* Atomics */
#ifdef CONFIG_ATOMICS

typedef enum AtomicsOpEnum {
    ATOMICS_OP_ADD,
    ATOMICS_OP_AND,
    ATOMICS_OP_OR,
    ATOMICS_OP_SUB,
    ATOMICS_OP_XOR,
    ATOMICS_OP_EXCHANGE,
    ATOMICS_OP_COMPARE_EXCHANGE,
    ATOMICS_OP_LOAD,
} AtomicsOpEnum;

static JSObject *js_atomics_get_buf(JSContext *ctx,
                                    JSValueConst obj, JSValueConst idx_val,
                                    JSArrayBuffer **pabuf,
                                    uint64_t *pindex, int is_waitable)
{
    JSObject *p;
    JSTypedArray *ta;
    JSArrayBuffer *abuf;
    uint64_t idx;
    bool err;

    if (JS_VALUE_GET_TAG(obj) != JS_TAG_OBJECT)
        goto fail;
    p = JS_VALUE_GET_OBJ(obj);
    if (is_waitable)
        err = (p->class_id != JS_CLASS_INT32_ARRAY &&
               p->class_id != JS_CLASS_BIG_INT64_ARRAY);
    else
        err = !(p->class_id >= JS_CLASS_INT8_ARRAY &&
                p->class_id <= JS_CLASS_BIG_UINT64_ARRAY);
    if (err) {
    fail:
        JS_ThrowTypeError(ctx, "integer TypedArray expected");
        return NULL;
    }
    ta = p->u.typed_array;
    abuf = ta->buffer->u.array_buffer;
    if (!abuf->shared) {
        if (is_waitable == 2) {
            JS_ThrowTypeError(ctx, "not a SharedArrayBuffer TypedArray");
            return NULL;
        }
        if (abuf->detached) {
            JS_ThrowTypeErrorDetachedArrayBuffer(ctx);
            return NULL;
        }
    }
    if (JS_ToIndex(ctx, &idx, idx_val)) {
        return NULL;
    }
    /* if the array buffer is detached, p->u.array.count = 0 */
    if (idx >= p->u.array.count) {
        JS_ThrowRangeError(ctx, "out-of-bound access");
        return NULL;
    }
    if (pabuf)
        *pabuf = abuf;
    *pindex = idx;
    return p;
}

static JSValue js_atomics_op(JSContext *ctx,
                             JSValueConst this_obj,
                             int argc, JSValueConst *argv, int op)
{
    int size_log2;
    uint64_t v, a, rep_val, idx;
    void *ptr;
    JSObject *p;
    JSValue ret;

    p = js_atomics_get_buf(ctx, argv[0], argv[1], NULL, &idx, 0);
    if (!p)
        return JS_EXCEPTION;
    size_log2 = typed_array_size_log2(p->class_id);
    rep_val = 0;
    if (op == ATOMICS_OP_LOAD) {
        v = 0;
    } else {
        if (size_log2 == 3) {
            int64_t v64;
            if (JS_ToBigInt64(ctx, &v64, argv[2]))
                return JS_EXCEPTION;
            v = v64;
            if (op == ATOMICS_OP_COMPARE_EXCHANGE) {
                if (JS_ToBigInt64(ctx, &v64, argv[3]))
                    return JS_EXCEPTION;
                rep_val = v64;
            }
        } else {
			uint32_t v32;
			if (JS_ToUint32(ctx, &v32, argv[2]))
				return JS_EXCEPTION;
			v = v32;
			if (op == ATOMICS_OP_COMPARE_EXCHANGE) {
				if (JS_ToUint32(ctx, &v32, argv[3]))
					return JS_EXCEPTION;
				rep_val = v32;
			}
        }
   }

    /* check if an evil .valueOf has resized or detached the array */
    if (idx >= p->u.array.count)
        return JS_ThrowRangeError(ctx, "out-of-bound access");

    ptr = p->u.array.u.uint8_ptr + ((uintptr_t)idx << size_log2);

   switch(op | (size_log2 << 3)) {

#define OP(op_name, func_name)                          \
    case ATOMICS_OP_ ## op_name | (0 << 3):             \
       a = func_name((_Atomic uint8_t *)ptr, v);        \
       break;                                           \
    case ATOMICS_OP_ ## op_name | (1 << 3):             \
        a = func_name((_Atomic uint16_t *)ptr, v);      \
        break;                                          \
    case ATOMICS_OP_ ## op_name | (2 << 3):             \
        a = func_name((_Atomic uint32_t *)ptr, v);      \
        break;                                          \
    case ATOMICS_OP_ ## op_name | (3 << 3):             \
        a = func_name((_Atomic uint64_t *)ptr, v);      \
        break;
        OP(ADD, atomic_fetch_add)
        OP(AND, atomic_fetch_and)
        OP(OR, atomic_fetch_or)
        OP(SUB, atomic_fetch_sub)
        OP(XOR, atomic_fetch_xor)
        OP(EXCHANGE, atomic_exchange)
#undef OP

    case ATOMICS_OP_LOAD | (0 << 3):
        a = atomic_load((_Atomic uint8_t *)ptr);
        break;
    case ATOMICS_OP_LOAD | (1 << 3):
        a = atomic_load((_Atomic uint16_t *)ptr);
        break;
    case ATOMICS_OP_LOAD | (2 << 3):
        a = atomic_load((_Atomic uint32_t *)ptr);
        break;
    case ATOMICS_OP_LOAD | (3 << 3):
        a = atomic_load((_Atomic uint64_t *)ptr);
        break;
    case ATOMICS_OP_COMPARE_EXCHANGE | (0 << 3):
        {
            uint8_t v1 = v;
            atomic_compare_exchange_strong((_Atomic uint8_t *)ptr, &v1, rep_val);
            a = v1;
        }
        break;
    case ATOMICS_OP_COMPARE_EXCHANGE | (1 << 3):
        {
            uint16_t v1 = v;
            atomic_compare_exchange_strong((_Atomic uint16_t *)ptr, &v1, rep_val);
            a = v1;
        }
        break;
    case ATOMICS_OP_COMPARE_EXCHANGE | (2 << 3):
        {
            uint32_t v1 = v;
            atomic_compare_exchange_strong((_Atomic uint32_t *)ptr, &v1, rep_val);
            a = v1;
        }
        break;
    case ATOMICS_OP_COMPARE_EXCHANGE | (3 << 3):
        {
            uint64_t v1 = v;
            atomic_compare_exchange_strong((_Atomic uint64_t *)ptr, &v1, rep_val);
            a = v1;
        }
        break;
    default:
        abort();
    }

    switch(p->class_id) {
    case JS_CLASS_INT8_ARRAY:
        a = (int8_t)a;
        goto done;
    case JS_CLASS_UINT8_ARRAY:
        a = (uint8_t)a;
        goto done;
    case JS_CLASS_INT16_ARRAY:
        a = (int16_t)a;
        goto done;
    case JS_CLASS_UINT16_ARRAY:
        a = (uint16_t)a;
        goto done;
    case JS_CLASS_INT32_ARRAY:
    done:
        ret = js_int32(a);
        break;
    case JS_CLASS_UINT32_ARRAY:
        ret = js_uint32(a);
        break;
    case JS_CLASS_BIG_INT64_ARRAY:
        ret = JS_NewBigInt64(ctx, a);
        break;
    case JS_CLASS_BIG_UINT64_ARRAY:
        ret = JS_NewBigUint64(ctx, a);
        break;
    default:
        abort();
    }
    return ret;
}

static JSValue js_atomics_store(JSContext *ctx,
                                JSValueConst this_obj,
                                int argc, JSValueConst *argv)
{
    int size_log2;
    uint64_t idx;
    void *ptr;
    JSObject *p;
    JSValue ret;

    p = js_atomics_get_buf(ctx, argv[0], argv[1], NULL, &idx, 0);
    if (!p)
        return JS_EXCEPTION;
    size_log2 = typed_array_size_log2(p->class_id);
    if (size_log2 == 3) {
        int64_t v64;
        ret = JS_ToBigIntFree(ctx, js_dup(argv[2]));
        if (JS_IsException(ret))
            return ret;
        if (JS_ToBigInt64(ctx, &v64, ret)) {
            JS_FreeValue(ctx, ret);
            return JS_EXCEPTION;
        }
        /* check if an evil .valueOf has resized or detached the array */
        if (idx >= p->u.array.count) {
            JS_FreeValue(ctx, ret);
            return JS_ThrowRangeError(ctx, "out-of-bound access");
        }
        ptr = p->u.array.u.uint8_ptr + ((uintptr_t)idx << size_log2);
        atomic_store((_Atomic uint64_t *)ptr, v64);
    } else {
        uint32_t v;
        /* XXX: spec, would be simpler to return the written value */
        ret = JS_ToIntegerFree(ctx, js_dup(argv[2]));
        if (JS_IsException(ret))
            return ret;
        if (JS_ToUint32(ctx, &v, ret)) {
            JS_FreeValue(ctx, ret);
            return JS_EXCEPTION;
        }
        /* check if an evil .valueOf has resized or detached the array */
        if (idx >= p->u.array.count) {
            JS_FreeValue(ctx, ret);
            return JS_ThrowRangeError(ctx, "out-of-bound access");
        }
        ptr = p->u.array.u.uint8_ptr + ((uintptr_t)idx << size_log2);
        switch(size_log2) {
        case 0:
            atomic_store((_Atomic uint8_t *)ptr, v);
            break;
        case 1:
            atomic_store((_Atomic uint16_t *)ptr, v);
            break;
        case 2:
            atomic_store((_Atomic uint32_t *)ptr, v);
            break;
        default:
            abort();
        }
    }
    return ret;
}

static JSValue js_atomics_isLockFree(JSContext *ctx,
                                     JSValueConst this_obj,
                                     int argc, JSValueConst *argv)
{
    int v, ret;
    if (JS_ToInt32Sat(ctx, &v, argv[0]))
        return JS_EXCEPTION;
    ret = (v == 1 || v == 2 || v == 4 || v == 8);
    return js_bool(ret);
}

typedef struct JSAtomicsWaiter {
    struct list_head link;
    bool linked;
    js_cond_t cond;
    int32_t *ptr;
} JSAtomicsWaiter;

static js_once_t js_atomics_once = JS_ONCE_INIT;
static js_mutex_t js_atomics_mutex;
static struct list_head js_atomics_waiter_list =
    LIST_HEAD_INIT(js_atomics_waiter_list);

// no-op: Atomics.pause() is not allowed to block or yield to another
// thread, only to hint the CPU that it should back off for a bit;
// the amount of work we do here is a good enough substitute
static JSValue js_atomics_pause(JSContext *ctx, JSValueConst this_obj,
                                int argc, JSValueConst *argv)
{
    double d;

    if (argc > 0) {
        switch (JS_VALUE_GET_NORM_TAG(argv[0])) {
        case JS_TAG_FLOAT64: // accepted if and only if fraction == 0.0
            d = JS_VALUE_GET_FLOAT64(argv[0]);
            if (isfinite(d))
                if (0 == modf(d, &d))
                    break;
            // fallthru
        default:
            return JS_ThrowTypeError(ctx, "not an integral number");
        case JS_TAG_UNDEFINED:
        case JS_TAG_INT:
            break;
        }
    }
    return JS_UNDEFINED;
}

static JSValue js_atomics_wait(JSContext *ctx,
                               JSValueConst this_obj,
                               int argc, JSValueConst *argv)
{
    int64_t v;
    int32_t v32;
    void *ptr;
    int64_t timeout;
    uint64_t idx;
    JSObject *p;
    JSAtomicsWaiter waiter_s, *waiter;
    int ret, size_log2, res;
    double d;

    p = js_atomics_get_buf(ctx, argv[0], argv[1], NULL, &idx, 2);
    if (!p)
        return JS_EXCEPTION;
    size_log2 = typed_array_size_log2(p->class_id);
    if (size_log2 == 3) {
        if (JS_ToBigInt64(ctx, &v, argv[2]))
            return JS_EXCEPTION;
    } else {
        if (JS_ToInt32(ctx, &v32, argv[2]))
            return JS_EXCEPTION;
        v = v32;
    }
    if (JS_ToFloat64(ctx, &d, argv[3]))
        return JS_EXCEPTION;
    if (isnan(d) || d >= 0x1p63)
        timeout = INT64_MAX;
    else if (d < 0)
        timeout = 0;
    else
        timeout = (int64_t)d;
    if (!ctx->rt->can_block)
        return JS_ThrowTypeError(ctx, "cannot block in this thread");

    /* check if an evil .valueOf has resized or detached the array */
    if (idx >= p->u.array.count)
        return JS_ThrowRangeError(ctx, "out-of-bound access");

    ptr = p->u.array.u.uint8_ptr + ((uintptr_t)idx << size_log2);

    /* XXX: inefficient if large number of waiters, should hash on
       'ptr' value */
    js_mutex_lock(&js_atomics_mutex);
    if (size_log2 == 3) {
        res = *(int64_t *)ptr != v;
    } else {
        res = *(int32_t *)ptr != v;
    }
    if (res) {
        js_mutex_unlock(&js_atomics_mutex);
        return JS_AtomToString(ctx, JS_ATOM_not_equal);
    }

    waiter = &waiter_s;
    waiter->ptr = ptr;
    js_cond_init(&waiter->cond);
    waiter->linked = true;
    list_add_tail(&waiter->link, &js_atomics_waiter_list);

    if (timeout == INT64_MAX) {
        js_cond_wait(&waiter->cond, &js_atomics_mutex);
        ret = 0;
    } else {
        ret = js_cond_timedwait(&waiter->cond, &js_atomics_mutex, timeout * 1e6 /* to ns */);
    }
    if (waiter->linked)
        list_del(&waiter->link);
    js_mutex_unlock(&js_atomics_mutex);
    js_cond_destroy(&waiter->cond);
    if (ret == -1) {
        return JS_AtomToString(ctx, JS_ATOM_timed_out);
    } else {
        return JS_AtomToString(ctx, JS_ATOM_ok);
    }
}

static JSValue js_atomics_notify(JSContext *ctx,
                                 JSValueConst this_obj,
                                 int argc, JSValueConst *argv)
{
    struct list_head *el, *el1, waiter_list;
    int size_log2;
    int count;
    int32_t n;
    void *ptr;
    uint64_t idx;
    JSObject *p;
    JSArrayBuffer *abuf;
    JSAtomicsWaiter *waiter;

    p = js_atomics_get_buf(ctx, argv[0], argv[1], &abuf, &idx, 1);
    if (!p)
        return JS_EXCEPTION;
    size_log2 = typed_array_size_log2(p->class_id);

    if (JS_IsUndefined(argv[2])) {
        count = INT32_MAX;
    } else {
        if (JS_ToInt32Clamp(ctx, &count, argv[2], 0, INT32_MAX, 0))
            return JS_EXCEPTION;
    }

    /* check if an evil .valueOf has resized or detached the array */
    if (idx >= p->u.array.count)
        return JS_ThrowRangeError(ctx, "out-of-bound access");

    n = 0;
    if (abuf->shared && count > 0) {
        ptr = p->u.array.u.uint8_ptr + ((uintptr_t)idx << size_log2);

        js_mutex_lock(&js_atomics_mutex);
        init_list_head(&waiter_list);
        list_for_each_safe(el, el1, &js_atomics_waiter_list) {
            waiter = list_entry(el, JSAtomicsWaiter, link);
            if (waiter->ptr == ptr) {
                list_del(&waiter->link);
                waiter->linked = false;
                list_add_tail(&waiter->link, &waiter_list);
                n++;
                if (n >= count)
                    break;
            }
        }
        list_for_each(el, &waiter_list) {
            waiter = list_entry(el, JSAtomicsWaiter, link);
            js_cond_signal(&waiter->cond);
        }
        js_mutex_unlock(&js_atomics_mutex);
    }
    return js_int32(n);
}

static const JSCFunctionListEntry js_atomics_funcs[] = {
    JS_CFUNC_MAGIC_DEF("add", 3, js_atomics_op, ATOMICS_OP_ADD ),
    JS_CFUNC_MAGIC_DEF("and", 3, js_atomics_op, ATOMICS_OP_AND ),
    JS_CFUNC_MAGIC_DEF("or", 3, js_atomics_op, ATOMICS_OP_OR ),
    JS_CFUNC_MAGIC_DEF("sub", 3, js_atomics_op, ATOMICS_OP_SUB ),
    JS_CFUNC_MAGIC_DEF("xor", 3, js_atomics_op, ATOMICS_OP_XOR ),
    JS_CFUNC_MAGIC_DEF("exchange", 3, js_atomics_op, ATOMICS_OP_EXCHANGE ),
    JS_CFUNC_MAGIC_DEF("compareExchange", 4, js_atomics_op, ATOMICS_OP_COMPARE_EXCHANGE ),
    JS_CFUNC_MAGIC_DEF("load", 2, js_atomics_op, ATOMICS_OP_LOAD ),
    JS_CFUNC_DEF("store", 3, js_atomics_store ),
    JS_CFUNC_DEF("isLockFree", 1, js_atomics_isLockFree ),
    JS_CFUNC_DEF("pause", 0, js_atomics_pause ),
    JS_CFUNC_DEF("wait", 4, js_atomics_wait ),
    JS_CFUNC_DEF("notify", 3, js_atomics_notify ),
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "Atomics", JS_PROP_CONFIGURABLE ),
};

static const JSCFunctionListEntry js_atomics_obj[] = {
    JS_OBJECT_DEF("Atomics", js_atomics_funcs, countof(js_atomics_funcs), JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE ),
};

static void js__atomics_init(void) {
    js_mutex_init(&js_atomics_mutex);
}

/* TODO(saghul) make this public and not dependent on typed arrays? */
static int JS_AddIntrinsicAtomics(JSContext *ctx)
{
    js_once(&js_atomics_once, js__atomics_init);

    /* add Atomics as autoinit object */
    return JS_SetPropertyFunctionList(ctx, ctx->global_obj, js_atomics_obj, countof(js_atomics_obj));
}

#endif /* CONFIG_ATOMICS */

static int js_uint8array_funcs_init(JSContext *ctx);

int JS_AddIntrinsicTypedArrays(JSContext *ctx)
{
    JSValue typed_array_base_func, typed_array_base_proto, obj;
    int i, ret;

    obj = JS_NewCConstructor(ctx, JS_CLASS_ARRAY_BUFFER, "ArrayBuffer",
                             js_array_buffer_constructor, 1, JS_CFUNC_constructor, 0,
                             JS_UNDEFINED,
                             js_array_buffer_funcs, countof(js_array_buffer_funcs),
                             js_array_buffer_proto_funcs, countof(js_array_buffer_proto_funcs),
                             0);
    if (JS_IsException(obj))
        return -1;
    JS_FreeValue(ctx, obj);

    obj = JS_NewCConstructor(ctx, JS_CLASS_SHARED_ARRAY_BUFFER, "SharedArrayBuffer",
                             js_shared_array_buffer_constructor, 1, JS_CFUNC_constructor, 0,
                             JS_UNDEFINED,
                             js_shared_array_buffer_funcs, countof(js_shared_array_buffer_funcs),
                             js_shared_array_buffer_proto_funcs, countof(js_shared_array_buffer_proto_funcs),
                             0);
    if (JS_IsException(obj))
        return -1;
    JS_FreeValue(ctx, obj);

    typed_array_base_func =
        JS_NewCConstructor(ctx, -1, "TypedArray",
                           js_typed_array_base_constructor, 0, JS_CFUNC_constructor_or_func, 0,
                           JS_UNDEFINED,
                           js_typed_array_base_funcs, countof(js_typed_array_base_funcs),
                           js_typed_array_base_proto_funcs, countof(js_typed_array_base_proto_funcs),
                           JS_NEW_CTOR_NO_GLOBAL);
    if (JS_IsException(typed_array_base_func))
        return -1;

    /* TypedArray.prototype.toString must be the same object as Array.prototype.toString */
    obj = JS_GetProperty(ctx, ctx->class_proto[JS_CLASS_ARRAY], JS_ATOM_toString);
    if (JS_IsException(obj))
        goto fail;
    /* XXX: should use alias method in JSCFunctionListEntry */ //@@@
    typed_array_base_proto = JS_GetProperty(ctx, typed_array_base_func, JS_ATOM_prototype);
    if (JS_IsException(typed_array_base_proto))
        goto fail;
    ret = JS_DefinePropertyValue(ctx, typed_array_base_proto, JS_ATOM_toString, obj,
                                 JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
    JS_FreeValue(ctx, typed_array_base_proto);
    if (ret < 0)
        goto fail;

    /* Used to squelch a -Wcast-function-type warning. */
    JSCFunctionType ft = { .generic_magic = js_typed_array_constructor };
    for(i = JS_CLASS_UINT8C_ARRAY; i < JS_CLASS_UINT8C_ARRAY + JS_TYPED_ARRAY_COUNT; i++) {
        char buf[ATOM_GET_STR_BUF_SIZE];
        const char *name;
        const JSCFunctionListEntry *bpe;

        name = JS_AtomGetStr(ctx, buf, sizeof(buf),
                             JS_ATOM_Uint8ClampedArray + i - JS_CLASS_UINT8C_ARRAY);
        bpe = js_typed_array_funcs + typed_array_size_log2(i);
        obj = JS_NewCConstructor(ctx, i, name,
                                 ft.generic, 3, JS_CFUNC_constructor_magic, i,
                                 typed_array_base_func,
                                 bpe, 1,
                                 bpe, 1,
                                 0);
        if (JS_IsException(obj)) {
        fail:
            JS_FreeValue(ctx, typed_array_base_func);
            return -1;
        }
        JS_FreeValue(ctx, obj);
    }
    JS_FreeValue(ctx, typed_array_base_func);

    /* Uint8Array base64/hex methods */
    if (js_uint8array_funcs_init(ctx))
        return -1;

    /* DataView */
    obj = JS_NewCConstructor(ctx, JS_CLASS_DATAVIEW, "DataView",
                             js_dataview_constructor, 1, JS_CFUNC_constructor, 0,
                             JS_UNDEFINED,
                             NULL, 0,
                             js_dataview_proto_funcs, countof(js_dataview_proto_funcs),
                             0);
    if (JS_IsException(obj))
        return -1;
    JS_FreeValue(ctx, obj);

    /* Atomics */
#ifdef CONFIG_ATOMICS
    if (JS_AddIntrinsicAtomics(ctx))
        return -1;
#endif
    return 0;
}

/* Performance */

static double js__now_ms(void)
{
    return js__hrtime_ns() / 1e6;
}

static JSValue js_perf_now(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    return js_float64(js__now_ms() - ctx->time_origin);
}

static const JSCFunctionListEntry js_perf_proto_funcs[] = {
    JS_CFUNC_DEF2("now", 0, js_perf_now, JS_PROP_ENUMERABLE),
};

int JS_AddPerformance(JSContext *ctx)
{
    ctx->time_origin = js__now_ms();

    JSValue performance = JS_NewObject(ctx);
    JS_SetPropertyFunctionList(ctx, performance, js_perf_proto_funcs, countof(js_perf_proto_funcs));
    JS_DefinePropertyValueStr(ctx, performance, "timeOrigin",
                           js_float64(ctx->time_origin),
                           JS_PROP_ENUMERABLE);
    JS_DefinePropertyValueStr(ctx, ctx->global_obj, "performance",
                           js_dup(performance),
                           JS_PROP_WRITABLE | JS_PROP_ENUMERABLE | JS_PROP_CONFIGURABLE);
    JS_FreeValue(ctx, performance);
    return 0;
}

/* Equality comparisons and sameness */
int JS_IsEqual(JSContext *ctx, JSValueConst op1, JSValueConst op2)
{
    JSValue sp[2] = { js_dup(op1), js_dup(op2) };
    if (js_eq_slow(ctx, endof(sp), 0))
        return -1;
    return JS_VALUE_GET_BOOL(sp[0]);
}

bool JS_IsStrictEqual(JSContext *ctx, JSValueConst op1, JSValueConst op2)
{
    return js_strict_eq2(ctx, op1, op2, JS_EQ_STRICT);
}

bool JS_IsSameValue(JSContext *ctx, JSValueConst op1, JSValueConst op2)
{
    return js_same_value(ctx, op1, op2);
}

bool JS_IsSameValueZero(JSContext *ctx, JSValueConst op1, JSValueConst op2)
{
    return js_same_value_zero(ctx, op1, op2);
}

/* WeakRef */

typedef struct JSWeakRefData {
    JSValueConst target;
    JSValue obj;
} JSWeakRefData;

static JSWeakRefData js_weakref_sentinel;

static void js_weakref_finalizer(JSRuntime *rt, JSValueConst val)
{
    JSWeakRefData *wrd = JS_GetOpaque(val, JS_CLASS_WEAK_REF);
    if (!wrd || wrd == &js_weakref_sentinel)
        return;

    /* Delete weak ref */
    JSWeakRefRecord **pwr, *wr;

    pwr = get_first_weak_ref(wrd->target);
    for(;;) {
        wr = *pwr;
        assert(wr != NULL);
        if (wr->kind == JS_WEAK_REF_KIND_WEAK_REF && wr->u.weak_ref_data == wrd)
            break;
        pwr = &wr->next_weak_ref;
    }
    *pwr = wr->next_weak_ref;
    js_free_rt(rt, wrd);
    js_free_rt(rt, wr);
}

static JSValue js_weakref_constructor(JSContext *ctx, JSValueConst new_target,
                                      int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target))
        return JS_ThrowTypeError(ctx, "constructor requires 'new'");
    JSValueConst arg = argv[0];
    if (!is_valid_weakref_target(arg))
        return JS_ThrowTypeError(ctx, "invalid target");
    // TODO(saghul): short-circuit if the refcount is 1?
    JSValue obj = js_create_from_ctor(ctx, new_target, JS_CLASS_WEAK_REF);
    if (JS_IsException(obj))
        return JS_EXCEPTION;
    JSWeakRefData *wrd = js_malloc(ctx, sizeof(*wrd));
    if (!wrd) {
        JS_FreeValue(ctx, obj);
        return JS_EXCEPTION;
    }
    JSWeakRefRecord *wr = js_malloc(ctx, sizeof(*wr));
    if (!wr) {
        JS_FreeValue(ctx, obj);
        js_free(ctx, wrd);
        return JS_EXCEPTION;
    }
    wrd->target = arg;
    wrd->obj = obj;
    wr->kind = JS_WEAK_REF_KIND_WEAK_REF;
    wr->u.weak_ref_data = wrd;
    insert_weakref_record(arg, wr);

    JS_SetOpaqueInternal(obj, wrd);
    return obj;
}

static JSValue js_weakref_deref(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSWeakRefData *wrd = JS_GetOpaque2(ctx, this_val, JS_CLASS_WEAK_REF);
    if (!wrd)
        return JS_EXCEPTION;
    if (wrd == &js_weakref_sentinel)
        return JS_UNDEFINED;
    return js_dup(wrd->target);
}

static const JSCFunctionListEntry js_weakref_proto_funcs[] = {
    JS_CFUNC_DEF("deref", 0, js_weakref_deref ),
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "WeakRef", JS_PROP_CONFIGURABLE ),
};

static const JSClassShortDef js_weakref_class_def[] = {
    { JS_ATOM_WeakRef, js_weakref_finalizer, NULL }, /* JS_CLASS_WEAK_REF */
};

typedef struct JSFinRecEntry {
    struct list_head link;
    JSValueConst target;
    JSValue held_val;
    JSValue token;
    JSValue cb;
    JSContext *ctx;
} JSFinRecEntry;

typedef struct JSFinalizationRegistryData {
    struct list_head entries;
    JSContext *ctx;
    JSValue cb;
} JSFinalizationRegistryData;

static void delete_finrec_weakref(JSRuntime *rt, JSFinRecEntry *fre)
{
    JSWeakRefRecord **pwr, *wr;

    pwr = get_first_weak_ref(fre->target);
    for(;;) {
        wr = *pwr;
        assert(wr != NULL);
        if (wr->kind == JS_WEAK_REF_KIND_FINALIZATION_REGISTRY_ENTRY && wr->u.fin_rec_entry == fre)
            break;
        pwr = &wr->next_weak_ref;
    }
    *pwr = wr->next_weak_ref;
    js_free_rt(rt, wr);
}

static void js_finrec_free(JSRuntime *rt, JSFinRecEntry *fre)
{
    JS_FreeValueRT(rt, fre->held_val);
    JS_FreeValueRT(rt, fre->token);
    JS_FreeValueRT(rt, fre->cb);
    JS_FreeContext(fre->ctx);
    js_free_rt(rt, fre);
}

static void js_finrec_finalizer(JSRuntime *rt, JSValueConst val)
{
    JSFinalizationRegistryData *frd = JS_GetOpaque(val, JS_CLASS_FINALIZATION_REGISTRY);
    if (frd) {
        struct list_head *el, *el1;
        /* first pass to remove the weak ref entries and avoid having them modified
           by freeing a token / held value. */
        list_for_each_safe(el, el1, &frd->entries) {
            JSFinRecEntry *fre = list_entry(el, JSFinRecEntry, link);
            delete_finrec_weakref(rt, fre);
        }
        /* second pass to actually free all objects. */
        list_for_each_safe(el, el1, &frd->entries) {
            JSFinRecEntry *fre = list_entry(el, JSFinRecEntry, link);
            list_del(&fre->link);
            js_finrec_free(rt, fre);
        }
        JS_FreeValueRT(rt, frd->cb);
        js_free_rt(rt, frd);
    }
}

static void js_finrec_mark(JSRuntime *rt, JSValueConst val,
                           JS_MarkFunc *mark_func)
{
    JSFinalizationRegistryData *frd = JS_GetOpaque(val, JS_CLASS_FINALIZATION_REGISTRY);
    if (frd) {
        JS_MarkValue(rt, frd->cb, mark_func);
        struct list_head *el;
        list_for_each(el, &frd->entries) {
            JSFinRecEntry *fre = list_entry(el, JSFinRecEntry, link);
            JS_MarkValue(rt, fre->held_val, mark_func);
            JS_MarkValue(rt, fre->token, mark_func);
            JS_MarkValue(rt, fre->cb, mark_func);
            mark_func(rt, &fre->ctx->header);
        }
    }
}

static JSValue js_finrec_constructor(JSContext *ctx, JSValueConst new_target,
                                     int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target))
        return JS_ThrowTypeError(ctx, "constructor requires 'new'");
    JSValueConst cb = argv[0];
    if (check_function(ctx, cb))
        return JS_EXCEPTION;
    JSValue obj = js_create_from_ctor(ctx, new_target, JS_CLASS_FINALIZATION_REGISTRY);
    if (JS_IsException(obj))
        return JS_EXCEPTION;
    JSFinalizationRegistryData *frd = js_malloc(ctx, sizeof(*frd));
    if (!frd) {
        JS_FreeValue(ctx, obj);
        return JS_EXCEPTION;
    }
    init_list_head(&frd->entries);
    frd->ctx = ctx;
    frd->cb = js_dup(cb);
    JS_SetOpaqueInternal(obj, frd);
    return obj;
}

static JSValue js_finrec_register(JSContext *ctx, JSValueConst this_val,
                                  int argc, JSValueConst *argv)
{
    JSFinalizationRegistryData *frd = JS_GetOpaque2(ctx, this_val, JS_CLASS_FINALIZATION_REGISTRY);
    if (!frd)
        return JS_EXCEPTION;

    JSValueConst target = argv[0];
    JSValueConst held_val = argv[1];
    // The function length needs to return 2, so the 3rd argument won't be initialized.
    JSValueConst token = argc > 2 ? argv[2] : JS_UNDEFINED;

    if (!is_valid_weakref_target(target))
        return JS_ThrowTypeError(ctx, "invalid target");
    if (js_same_value(ctx, target, this_val))
        return JS_UNDEFINED;
    if (!JS_IsUndefined(held_val) && js_same_value(ctx, target, held_val))
        return JS_ThrowTypeError(ctx, "held value cannot be the target");
    if (!JS_IsUndefined(token) && !is_valid_weakref_target(token))
        return JS_ThrowTypeError(ctx, "invalid unregister token");

    JSFinRecEntry *fre = js_malloc(ctx, sizeof(*fre));
    if (!fre)
        return JS_EXCEPTION;
    JSWeakRefRecord *wr = js_malloc(ctx, sizeof(*wr));
    if (!wr) {
        js_free(ctx, fre);
        return JS_EXCEPTION;
    }
    fre->cb = js_dup(frd->cb);
    fre->ctx = JS_DupContext(frd->ctx);
    fre->target = target;
    fre->held_val = js_dup(held_val);
    fre->token = js_dup(token);
    list_add_tail(&fre->link, &frd->entries);
    wr->kind = JS_WEAK_REF_KIND_FINALIZATION_REGISTRY_ENTRY;
    wr->u.fin_rec_entry = fre;
    insert_weakref_record(target, wr);

    return JS_UNDEFINED;
}

static JSValue js_finrec_unregister(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSFinalizationRegistryData *frd = JS_GetOpaque2(ctx, this_val, JS_CLASS_FINALIZATION_REGISTRY);
    if (!frd)
        return JS_EXCEPTION;

    JSValueConst token = argv[0];
    if (!is_valid_weakref_target(token))
        return JS_ThrowTypeError(ctx, "invalid unregister token");

    struct list_head *el, *el1;
    bool removed = false;
    list_for_each_safe(el, el1, &frd->entries) {
        JSFinRecEntry *fre = list_entry(el, JSFinRecEntry, link);
        if (js_same_value(ctx, fre->token, token)) {
            list_del(&fre->link);
            delete_finrec_weakref(ctx->rt, fre);
            js_finrec_free(ctx->rt, fre);
            removed = true;
        }
    }

    return js_bool(removed);
}

static const JSCFunctionListEntry js_finrec_proto_funcs[] = {
    JS_CFUNC_DEF("register", 2, js_finrec_register ),
    JS_CFUNC_DEF("unregister", 1, js_finrec_unregister ),
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "FinalizationRegistry", JS_PROP_CONFIGURABLE ),
};

static const JSClassShortDef js_finrec_class_def[] = {
    { JS_ATOM_FinalizationRegistry, js_finrec_finalizer, js_finrec_mark }, /* JS_CLASS_FINALIZATION_REGISTRY */
};

static JSValue js_finrec_job(JSContext *ctx, int argc, JSValueConst *argv)
{
    return JS_Call(ctx, argv[0], JS_UNDEFINED, 1, &argv[1]);
}

int JS_AddIntrinsicWeakRef(JSContext *ctx)
{
    JSRuntime *rt = ctx->rt;
    JSValue obj;

    /* WeakRef */
    if (!JS_IsRegisteredClass(rt, JS_CLASS_WEAK_REF)) {
        if (init_class_range(rt, js_weakref_class_def, JS_CLASS_WEAK_REF,
                             countof(js_weakref_class_def)))
            return -1;
    }
    obj = JS_NewCConstructor(ctx, JS_CLASS_WEAK_REF, "WeakRef",
                             js_weakref_constructor, 1, JS_CFUNC_constructor_or_func, 0,
                             JS_UNDEFINED,
                             NULL, 0,
                             js_weakref_proto_funcs, countof(js_weakref_proto_funcs),
                             0);
    if (JS_IsException(obj))
        return -1;
    JS_FreeValue(ctx, obj);

    /* FinalizationRegistry */
    if (!JS_IsRegisteredClass(rt, JS_CLASS_FINALIZATION_REGISTRY)) {
        if (init_class_range(rt, js_finrec_class_def, JS_CLASS_FINALIZATION_REGISTRY,
                             countof(js_finrec_class_def)))
            return -1;
    }
    obj = JS_NewCConstructor(ctx, JS_CLASS_FINALIZATION_REGISTRY, "FinalizationRegistry",
                             js_finrec_constructor, 1, JS_CFUNC_constructor_or_func, 0,
                             JS_UNDEFINED,
                             NULL, 0,
                             js_finrec_proto_funcs, countof(js_finrec_proto_funcs),
                             0);
    if (JS_IsException(obj))
        return -1;
    JS_FreeValue(ctx, obj);
    return 0;
}

static void reset_weak_ref(JSRuntime *rt, JSWeakRefRecord **first_weak_ref)
{
    JSWeakRefRecord *wr, *wr_next;
    JSWeakRefData *wrd;
    JSMapRecord *mr;
    JSMapState *s;
    JSFinRecEntry *fre;

    /* first pass to remove the records from the WeakMap/WeakSet
       lists */
    for(wr = *first_weak_ref; wr != NULL; wr = wr->next_weak_ref) {
        switch(wr->kind) {
        case JS_WEAK_REF_KIND_MAP:
            mr = wr->u.map_record;
            s = mr->map;
            assert(s->is_weak);
            assert(!mr->empty); /* no iterator on WeakMap/WeakSet */
            list_del(&mr->hash_link);
            list_del(&mr->link);
            s->record_count--;
            break;
        case JS_WEAK_REF_KIND_WEAK_REF:
            wrd = wr->u.weak_ref_data;
            wrd->target = JS_UNDEFINED;
            break;
        case JS_WEAK_REF_KIND_FINALIZATION_REGISTRY_ENTRY:
            fre = wr->u.fin_rec_entry;
            list_del(&fre->link);
            break;
        default:
            abort();
        }
    }

    /* second pass to free the values to avoid modifying the weak
       reference list while traversing it. */
    for(wr = *first_weak_ref; wr != NULL; wr = wr_next) {
        wr_next = wr->next_weak_ref;
        switch(wr->kind) {
        case JS_WEAK_REF_KIND_MAP:
            mr = wr->u.map_record;
            JS_FreeValueRT(rt, mr->value);
            js_free_rt(rt, mr);
            break;
        case JS_WEAK_REF_KIND_WEAK_REF:
            wrd = wr->u.weak_ref_data;
            JS_SetOpaqueInternal(wrd->obj, &js_weakref_sentinel);
            js_free_rt(rt, wrd);
            break;
        case JS_WEAK_REF_KIND_FINALIZATION_REGISTRY_ENTRY: {
            fre = wr->u.fin_rec_entry;
            /**
             * During the GC sweep phase the held object might be
             * collected first (free_mark set). Also skip if the
             * callback or held value are part of a cycle being
             * collected (header.mark is set for objects on
             * tmp_obj_list during gc_free_cycles).
             */
            bool enqueue = !rt->in_free;
            if (enqueue && JS_IsObject(fre->held_val)) {
                JSObject *p = JS_VALUE_GET_OBJ(fre->held_val);
                if (p->free_mark || JS_GC_MARK(p))
                    enqueue = false;
            }
            if (enqueue && JS_IsObject(fre->cb)) {
                JSObject *p = JS_VALUE_GET_OBJ(fre->cb);
                if (p->free_mark || JS_GC_MARK(p))
                    enqueue = false;
            }
            if (enqueue) {
                JSValueConst args[2];
                args[0] = fre->cb;
                args[1] = fre->held_val;
                JS_EnqueueJob(fre->ctx, js_finrec_job, 2, args);
            }
            js_finrec_free(rt, fre);
            break;
        }
        default:
            abort();
        }
        js_free_rt(rt, wr);
    }

    *first_weak_ref = NULL; /* fail safe */
}

static bool is_valid_weakref_target(JSValueConst val)
{
    switch (JS_VALUE_GET_TAG(val)) {
    case JS_TAG_OBJECT:
        break;
    case JS_TAG_SYMBOL: {
        // Per spec: prohibit symbols registered with Symbol.for()
        JSAtomStruct *p = JS_VALUE_GET_PTR(val);
        if (p->atom_type != JS_ATOM_TYPE_GLOBAL_SYMBOL)
            break;
        // fallthru
    }
    default:
        return false;
    }

    return true;
}

static void insert_weakref_record(JSValueConst target,
                                  struct JSWeakRefRecord *wr)
{
    JSWeakRefRecord **pwr = get_first_weak_ref(target);
    /* Add the weak reference */
    wr->next_weak_ref = *pwr;
    *pwr = wr;
}

/* CallSite */

static void js_callsite_finalizer(JSRuntime *rt, JSValueConst val)
{
    JSCallSiteData *csd = JS_GetOpaque(val, JS_CLASS_CALL_SITE);
    if (csd) {
        JS_FreeValueRT(rt, csd->filename);
        JS_FreeValueRT(rt, csd->func);
        JS_FreeValueRT(rt, csd->func_name);
        js_free_rt(rt, csd);
    }
}

static void js_callsite_mark(JSRuntime *rt, JSValueConst val,
                             JS_MarkFunc *mark_func)
{
    JSCallSiteData *csd = JS_GetOpaque(val, JS_CLASS_CALL_SITE);
    if (csd) {
        JS_MarkValue(rt, csd->filename, mark_func);
        JS_MarkValue(rt, csd->func, mark_func);
        JS_MarkValue(rt, csd->func_name, mark_func);
    }
}

static JSValue js_new_callsite(JSContext *ctx, JSCallSiteData *csd) {
    JSValue obj = js_create_from_ctor(ctx, JS_UNDEFINED, JS_CLASS_CALL_SITE);
    if (JS_IsException(obj))
        return JS_EXCEPTION;

    JSCallSiteData *csd1 = js_malloc(ctx, sizeof(*csd));
    if (!csd1) {
        JS_FreeValue(ctx, obj);
        return JS_EXCEPTION;
    }

    /* The new object takes ownership of the values in |csd|; clear them so
       the caller doesn't free them a second time. */
    memcpy(csd1, csd, sizeof(*csd));
    csd->filename = JS_UNDEFINED;
    csd->func = JS_UNDEFINED;
    csd->func_name = JS_UNDEFINED;

    JS_SetOpaqueInternal(obj, csd1);

    return obj;
}

static void js_new_callsite_data(JSContext *ctx, JSCallSiteData *csd, JSStackFrame *sf)
{
    const char *func_name_str;
    JSObject *p;

    csd->constructor = sf->is_constructor;
    csd->func = js_dup(sf->cur_func);
    /* func_name_str is UTF-8 encoded if needed */
    func_name_str = get_func_name(ctx, sf->cur_func);
    if (!func_name_str || func_name_str[0] == '\0')
        csd->func_name = JS_NULL;
    else
        csd->func_name = JS_NewString(ctx, func_name_str);
    JS_FreeCString(ctx, func_name_str);
    if (JS_IsException(csd->func_name))
        csd->func_name = JS_NULL;

    p = JS_VALUE_GET_OBJ(sf->cur_func);
    if (js_class_has_bytecode(p->class_id)) {
        JSFunctionBytecode *b = p->u.func.function_bytecode;
        int line_num1, col_num1;
        line_num1 = find_line_num(ctx, b,
                                  sf->cur_pc - b->byte_code_buf - 1,
                                  &col_num1);
        csd->native = false;
        csd->line_num = line_num1;
        csd->col_num = col_num1;
        csd->filename = JS_AtomToString(ctx, b->filename);
        if (JS_IsException(csd->filename)) {
            csd->filename = JS_NULL;
            JS_FreeValue(ctx, JS_GetException(ctx)); // Clear exception.
        }
    } else {
        csd->native = true;
        csd->line_num = -1;
        csd->col_num = -1;
        csd->filename = JS_NULL;
    }
}

static void js_new_callsite_data2(JSContext *ctx, JSCallSiteData *csd, const char *filename, int line_num, int col_num)
{
    csd->func = JS_NULL;
    csd->func_name = JS_NULL;
    csd->native = false;
    csd->constructor = false;
    csd->line_num = line_num;
    csd->col_num = col_num;
    /* filename is UTF-8 encoded if needed (original argument to __JS_EvalInternal()) */
    csd->filename = JS_NewString(ctx, filename);
    if (JS_IsException(csd->filename)) {
        csd->filename = JS_NULL;
        JS_FreeValue(ctx, JS_GetException(ctx)); // Clear exception.
    }
}

static JSValue js_callsite_getfield(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic)
{
    JSCallSiteData *csd = JS_GetOpaque2(ctx, this_val, JS_CLASS_CALL_SITE);
    if (!csd)
        return JS_EXCEPTION;
    JSValue *field = (void *)((char *)csd + magic);
    return js_dup(*field);
}

static JSValue js_callsite_isnative(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSCallSiteData *csd = JS_GetOpaque2(ctx, this_val, JS_CLASS_CALL_SITE);
    if (!csd)
        return JS_EXCEPTION;
    return js_bool(csd->native);
}

static JSValue js_callsite_isconstructor(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv)
{
    JSCallSiteData *csd = JS_GetOpaque2(ctx, this_val, JS_CLASS_CALL_SITE);
    if (!csd)
        return JS_EXCEPTION;
    return js_bool(csd->constructor);
}

static JSValue js_callsite_getnumber(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic)
{
    JSCallSiteData *csd = JS_GetOpaque2(ctx, this_val, JS_CLASS_CALL_SITE);
    if (!csd)
        return JS_EXCEPTION;
    int *field = (void *)((char *)csd + magic);
    /* V8 returns null when the frame has no source position (native frames) */
    if (*field < 0)
        return JS_NULL;
    return js_int32(*field);
}

static const JSCFunctionListEntry js_callsite_proto_funcs[] = {
    JS_CFUNC_DEF("isNative", 0, js_callsite_isnative),
    JS_CFUNC_DEF("isConstructor", 0, js_callsite_isconstructor),
    JS_CFUNC_MAGIC_DEF("getFileName", 0, js_callsite_getfield, offsetof(JSCallSiteData, filename)),
    JS_CFUNC_MAGIC_DEF("getFunction", 0, js_callsite_getfield, offsetof(JSCallSiteData, func)),
    JS_CFUNC_MAGIC_DEF("getFunctionName", 0, js_callsite_getfield, offsetof(JSCallSiteData, func_name)),
    JS_CFUNC_MAGIC_DEF("getColumnNumber", 0, js_callsite_getnumber, offsetof(JSCallSiteData, col_num)),
    JS_CFUNC_MAGIC_DEF("getLineNumber", 0, js_callsite_getnumber, offsetof(JSCallSiteData, line_num)),
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "CallSite", JS_PROP_CONFIGURABLE ),
};

static const JSClassShortDef js_callsite_class_def[] = {
    { JS_ATOM_CallSite, js_callsite_finalizer, js_callsite_mark }, /* JS_CLASS_CALL_SITE */
};

static int _JS_AddIntrinsicCallSite(JSContext *ctx)
{
    JSRuntime *rt = ctx->rt;

    if (!JS_IsRegisteredClass(rt, JS_CLASS_CALL_SITE)) {
        if (init_class_range(rt, js_callsite_class_def, JS_CLASS_CALL_SITE,
                             countof(js_callsite_class_def)))
            return -1;
    }
    ctx->class_proto[JS_CLASS_CALL_SITE] = JS_NewObject(ctx);
    return JS_SetPropertyFunctionList(ctx, ctx->class_proto[JS_CLASS_CALL_SITE],
                                      js_callsite_proto_funcs,
                                      countof(js_callsite_proto_funcs));
}

/* DOMException */
typedef struct JSDOMExceptionData {
    JSValue name;
    JSValue message;
    int code;
} JSDOMExceptionData;

typedef struct JSDOMExceptionNameDef {
    const char * const name;
    const char * const code_name;
} JSDOMExceptionNameDef;

static const JSDOMExceptionNameDef js_dom_exception_names_table[] = {
    { "IndexSizeError", "INDEX_SIZE_ERR" },
    { NULL, "DOMSTRING_SIZE_ERR" },
    { "HierarchyRequestError", "HIERARCHY_REQUEST_ERR" },
    { "WrongDocumentError", "WRONG_DOCUMENT_ERR" },
    { "InvalidCharacterError", "INVALID_CHARACTER_ERR" },
    { NULL, "NO_DATA_ALLOWED_ERR" },
    { "NoModificationAllowedError", "NO_MODIFICATION_ALLOWED_ERR" },
    { "NotFoundError", "NOT_FOUND_ERR" },
    { "NotSupportedError", "NOT_SUPPORTED_ERR" },
    { "InUseAttributeError", "INUSE_ATTRIBUTE_ERR" },
    { "InvalidStateError", "INVALID_STATE_ERR" },
    { "SyntaxError", "SYNTAX_ERR" },
    { "InvalidModificationError", "INVALID_MODIFICATION_ERR" },
    { "NamespaceError", "NAMESPACE_ERR" },
    { "InvalidAccessError", "INVALID_ACCESS_ERR" },
    { NULL, "VALIDATION_ERR" },
    { "TypeMismatchError", "TYPE_MISMATCH_ERR" },
    { "SecurityError", "SECURITY_ERR" },
    { "NetworkError", "NETWORK_ERR" },
    { "AbortError", "ABORT_ERR" },
    { "URLMismatchError", "URL_MISMATCH_ERR" },
    { "QuotaExceededError", "QUOTA_EXCEEDED_ERR" },
    { "TimeoutError", "TIMEOUT_ERR" },
    { "InvalidNodeTypeError", "INVALID_NODE_TYPE_ERR" },
    { "DataCloneError", "DATA_CLONE_ERR" }
};

static void js_domexception_finalizer(JSRuntime *rt, JSValueConst val)
{
    JSDOMExceptionData *s = JS_GetOpaque(val, JS_CLASS_DOM_EXCEPTION);
    if (s) {
        JS_FreeValueRT(rt, s->name);
        JS_FreeValueRT(rt, s->message);
        js_free_rt(rt, s);
    }
}

static void js_domexception_mark(JSRuntime *rt, JSValueConst val,
                                 JS_MarkFunc *mark_func)
{
    JSDOMExceptionData *s = JS_GetOpaque(val, JS_CLASS_DOM_EXCEPTION);
    if (s) {
        JS_MarkValue(rt, s->name, mark_func);
        JS_MarkValue(rt, s->message, mark_func);
    }
}

static JSValue js_domexception_constructor0(JSContext *ctx, JSValueConst new_target,
                                            int argc, JSValueConst *argv,
                                            int backtrace_flags)
{
    JSDOMExceptionData *s;
    JSValue obj, message, name;

    obj = js_create_from_ctor(ctx, new_target, JS_CLASS_DOM_EXCEPTION);
    if (JS_IsException(obj))
        return JS_EXCEPTION;
    if (argc > 0 && !JS_IsUndefined(argv[0]))
        message = JS_ToString(ctx, argv[0]);
    else
        message = js_empty_string(ctx->rt);
    if (JS_IsException(message))
        goto fail1;
    if (argc > 1 && !JS_IsUndefined(argv[1]))
        name = JS_ToString(ctx, argv[1]);
    else
        name = JS_AtomToString(ctx, JS_ATOM_Error);
    if (JS_IsException(name))
        goto fail2;
    s = js_malloc(ctx, sizeof(*s));
    if (!s)
        goto fail3;
    s->name = name;
    s->message = message;
    s->code = -1;
    JS_SetOpaqueInternal(obj, s);
    build_backtrace(ctx, obj, JS_UNDEFINED, NULL, 0, 0, backtrace_flags);
    return obj;
fail3:
    JS_FreeValue(ctx, name);
fail2:
    JS_FreeValue(ctx, message);
fail1:
    JS_FreeValue(ctx, obj);
    return JS_EXCEPTION;
}

static JSValue js_domexception_constructor(JSContext *ctx, JSValueConst new_target,
                                           int argc, JSValueConst *argv)
{
    if (JS_IsUndefined(new_target))
        return JS_ThrowTypeError(ctx, "constructor requires 'new'");
    return js_domexception_constructor0(ctx, new_target, argc, argv,
                                        JS_BACKTRACE_FLAG_SKIP_FIRST_LEVEL);
}

static JSValue js_domexception_getfield(JSContext *ctx, JSValueConst this_val,
                                        int magic)
{
    JSDOMExceptionData *s;
    JSValue *valp;

    s = JS_GetOpaque2(ctx, this_val, JS_CLASS_DOM_EXCEPTION);
    if (!s)
        return JS_EXCEPTION;
    valp = (void *)((char *)s + magic);
    return js_dup(*valp);
}

static JSValue js_domexception_get_code(JSContext *ctx, JSValueConst this_val)
{
    JSDOMExceptionData *s;
    const char *name, *it;
    int i;
    size_t len;

    s = JS_GetOpaque2(ctx, this_val, JS_CLASS_DOM_EXCEPTION);
    if (!s)
        return JS_EXCEPTION;
    if (s->code == -1) {
        name = JS_ToCStringLen(ctx, &len, s->name);
        if (!name)
            return JS_EXCEPTION;
        for (i = 0; i < countof(js_dom_exception_names_table); i++) {
            it = js_dom_exception_names_table[i].name;
            if (it && !strcmp(it, name) && len == strlen(it)) {
                s->code = i;
                break;
            }
        }
        s->code++;
        JS_FreeCString(ctx, name);
    }
    return js_int32(s->code);
}

static const JSCFunctionListEntry js_domexception_proto_funcs[] = {
    JS_CGETSET_MAGIC_DEF2("name", js_domexception_getfield, NULL,
        offsetof(JSDOMExceptionData, name), JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE ),
    JS_CGETSET_MAGIC_DEF2("message", js_domexception_getfield, NULL,
        offsetof(JSDOMExceptionData, message), JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE ),
    JS_CGETSET_DEF2("code", js_domexception_get_code, NULL,
        JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE ),
    JS_PROP_STRING_DEF("[Symbol.toStringTag]", "DOMException", JS_PROP_CONFIGURABLE ),
};

static const JSClassShortDef js_domexception_class_def[] = {
    { JS_ATOM_DOMException, js_domexception_finalizer, js_domexception_mark }, /* JS_CLASS_DOM_EXCEPTION */
};

JSValue JS_PRINTF_FORMAT_ATTR(3, 4) JS_ThrowDOMException(JSContext *ctx, const char *name, JS_PRINTF_FORMAT const char *fmt, ...)
{
    JSValue obj, js_name, js_message;
    JSValueConst argv[2];
    va_list ap;
    char buf[256];

    assert(JS_IsRegisteredClass(ctx->rt, JS_CLASS_DOM_EXCEPTION));
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    js_name = JS_NewString(ctx, name);
    if (JS_IsException(js_name))
        return JS_EXCEPTION;
    js_message = JS_NewString(ctx, buf);
    if (JS_IsException(js_message)) {
        JS_FreeValue(ctx, js_name);
        return JS_EXCEPTION;
    }
    argv[0] = js_message;
    argv[1] = js_name;
    obj = js_domexception_constructor0(ctx, JS_UNDEFINED, 2, argv, 0);
    JS_FreeValue(ctx, js_message);
    JS_FreeValue(ctx, js_name);
    if (JS_IsException(obj))
        return JS_EXCEPTION;
    return JS_Throw(ctx, obj);
}

int JS_AddIntrinsicDOMException(JSContext *ctx)
{
    JSRuntime *rt = ctx->rt;
    int i;
    JSAtom name;
    JSValue ctor, proto;

    if (!JS_IsRegisteredClass(rt, JS_CLASS_DOM_EXCEPTION)) {
        if (init_class_range(rt, js_domexception_class_def, JS_CLASS_DOM_EXCEPTION,
                             countof(js_domexception_class_def)))
            return -1;
    }
    proto = JS_NewObjectClass(ctx, JS_CLASS_ERROR);
    JS_SetPropertyFunctionList(ctx, proto,
                               js_domexception_proto_funcs,
                               countof(js_domexception_proto_funcs));
    ctor = JS_NewCFunction2(ctx, js_domexception_constructor, "DOMException", 0,
                            JS_CFUNC_constructor_or_func, 0);
    JS_SetConstructor(ctx, ctor, proto);
    for (i = 0; i < countof(js_dom_exception_names_table); i++) {
        name = JS_NewAtom(ctx, js_dom_exception_names_table[i].code_name);
        JS_DefinePropertyValue(ctx, proto, name, js_int32(i + 1),
                               JS_PROP_ENUMERABLE);
        JS_DefinePropertyValue(ctx, ctor, name, js_int32(i + 1),
                               JS_PROP_ENUMERABLE);
        JS_FreeAtom(ctx, name);
    }
    JS_DefinePropertyValue(ctx, ctx->global_obj, JS_ATOM_DOMException, ctor,
                           JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE);
    set_value(ctx, &ctx->class_proto[JS_CLASS_DOM_EXCEPTION], proto);
    return 0;
}
/* base64 */

static const unsigned char b64_enc[64] = {
    'A','B','C','D','E','F','G','H','I','J','K','L','M','N','O','P',
    'Q','R','S','T','U','V','W','X','Y','Z',
    'a','b','c','d','e','f','g','h','i','j','k','l','m','n','o','p',
    'q','r','s','t','u','v','w','x','y','z',
    '0','1','2','3','4','5','6','7','8','9',
    '+','/'
};

static const unsigned char b64url_enc[64] = {
    'A','B','C','D','E','F','G','H','I','J','K','L','M','N','O','P',
    'Q','R','S','T','U','V','W','X','Y','Z',
    'a','b','c','d','e','f','g','h','i','j','k','l','m','n','o','p',
    'q','r','s','t','u','v','w','x','y','z',
    '0','1','2','3','4','5','6','7','8','9',
    '-','_'
};

enum { K_VAL = 1u, K_WS = 2u };

static const uint8_t b64_val[256] = {
    ['A']=0, ['B']=1, ['C']=2, ['D']=3, ['E']=4, ['F']=5, ['G']=6, ['H']=7,
    ['I']=8, ['J']=9, ['K']=10,['L']=11,['M']=12,['N']=13,['O']=14,['P']=15,
    ['Q']=16,['R']=17,['S']=18,['T']=19,['U']=20,['V']=21,['W']=22,['X']=23,['Y']=24,['Z']=25,
    ['a']=26,['b']=27,['c']=28,['d']=29,['e']=30,['f']=31,['g']=32,['h']=33,
    ['i']=34,['j']=35,['k']=36,['l']=37,['m']=38,['n']=39,['o']=40,['p']=41,
    ['q']=42,['r']=43,['s']=44,['t']=45,['u']=46,['v']=47,['w']=48,['x']=49,['y']=50,['z']=51,
    ['0']=52,['1']=53,['2']=54,['3']=55,['4']=56,['5']=57,['6']=58,['7']=59,['8']=60,['9']=61,
    ['+']=62, ['/']=63,
    ['-']=62, ['_']=63,
};

static const char b64_flags[256] = {
    [' ']=K_WS, ['\t']=K_WS, ['\n']=K_WS, ['\f']=K_WS, ['\r']=K_WS,
    ['A']=K_VAL,['B']=K_VAL,['C']=K_VAL,['D']=K_VAL,['E']=K_VAL,['F']=K_VAL,['G']=K_VAL,['H']=K_VAL,
    ['I']=K_VAL,['J']=K_VAL,['K']=K_VAL,['L']=K_VAL,['M']=K_VAL,['N']=K_VAL,['O']=K_VAL,['P']=K_VAL,
    ['Q']=K_VAL,['R']=K_VAL,['S']=K_VAL,['T']=K_VAL,['U']=K_VAL,['V']=K_VAL,['W']=K_VAL,['X']=K_VAL,
    ['Y']=K_VAL,['Z']=K_VAL,
    ['a']=K_VAL,['b']=K_VAL,['c']=K_VAL,['d']=K_VAL,['e']=K_VAL,['f']=K_VAL,['g']=K_VAL,['h']=K_VAL,
    ['i']=K_VAL,['j']=K_VAL,['k']=K_VAL,['l']=K_VAL,['m']=K_VAL,['n']=K_VAL,['o']=K_VAL,['p']=K_VAL,
    ['q']=K_VAL,['r']=K_VAL,['s']=K_VAL,['t']=K_VAL,['u']=K_VAL,['v']=K_VAL,['w']=K_VAL,['x']=K_VAL,
    ['y']=K_VAL,['z']=K_VAL,
    ['0']=K_VAL,['1']=K_VAL,['2']=K_VAL,['3']=K_VAL,['4']=K_VAL,['5']=K_VAL,['6']=K_VAL,['7']=K_VAL,
    ['8']=K_VAL,['9']=K_VAL,
    ['+']=K_VAL,['/']=K_VAL,
};

static const char b64_flags_url[256] = {
    [' ']=K_WS, ['\t']=K_WS, ['\n']=K_WS, ['\f']=K_WS, ['\r']=K_WS,
    ['A']=K_VAL,['B']=K_VAL,['C']=K_VAL,['D']=K_VAL,['E']=K_VAL,['F']=K_VAL,['G']=K_VAL,['H']=K_VAL,
    ['I']=K_VAL,['J']=K_VAL,['K']=K_VAL,['L']=K_VAL,['M']=K_VAL,['N']=K_VAL,['O']=K_VAL,['P']=K_VAL,
    ['Q']=K_VAL,['R']=K_VAL,['S']=K_VAL,['T']=K_VAL,['U']=K_VAL,['V']=K_VAL,['W']=K_VAL,['X']=K_VAL,
    ['Y']=K_VAL,['Z']=K_VAL,
    ['a']=K_VAL,['b']=K_VAL,['c']=K_VAL,['d']=K_VAL,['e']=K_VAL,['f']=K_VAL,['g']=K_VAL,['h']=K_VAL,
    ['i']=K_VAL,['j']=K_VAL,['k']=K_VAL,['l']=K_VAL,['m']=K_VAL,['n']=K_VAL,['o']=K_VAL,['p']=K_VAL,
    ['q']=K_VAL,['r']=K_VAL,['s']=K_VAL,['t']=K_VAL,['u']=K_VAL,['v']=K_VAL,['w']=K_VAL,['x']=K_VAL,
    ['y']=K_VAL,['z']=K_VAL,
    ['0']=K_VAL,['1']=K_VAL,['2']=K_VAL,['3']=K_VAL,['4']=K_VAL,['5']=K_VAL,['6']=K_VAL,['7']=K_VAL,
    ['8']=K_VAL,['9']=K_VAL,
    ['-']=K_VAL,['_']=K_VAL,
};

static size_t b64_encode(const uint8_t *src, size_t len, char *dst,
                         const unsigned char *alpha)
{
    size_t i = 0, j = 0;
    size_t main_len = (len / 3) * 3;

    for (; i < main_len; i += 3, j += 4) {
        uint32_t v = 65536*src[i] + 256*src[i + 1] + src[i + 2];
        dst[j + 0] = alpha[(v >> 18) & 63];
        dst[j + 1] = alpha[(v >> 12) & 63];
        dst[j + 2] = alpha[(v >> 6) & 63];
        dst[j + 3] = alpha[v & 63];
    }

    size_t rem = len - i;
    if (rem == 1) {
        uint32_t v = 65536*src[i];
        dst[j++] = alpha[(v >> 18) & 63];
        dst[j++] = alpha[(v >> 12) & 63];
        dst[j++] = '=';
        dst[j++] = '=';
    } else if (rem == 2) {
        uint32_t v = 65536*src[i] + 256*src[i + 1];
        dst[j++] = alpha[(v >> 18) & 63];
        dst[j++] = alpha[(v >> 12) & 63];
        dst[j++] = alpha[(v >> 6) & 63];
        dst[j++] = '=';
    }
    return j;
}

/* Implements https://infra.spec.whatwg.org/#forgiving-base64-decode */
static size_t
b64_decode(const char *src, size_t len, uint8_t *dst, int *err)
{
    size_t i, j;
    uint32_t acc;
    int seen, pad;
    unsigned ch;

    acc = 0;
    seen = 0;
    for (i = 0, j = 0; i < len; i++) {
        ch = (unsigned char)src[i];
        if ((b64_flags[ch] & K_WS))
            continue;
        if (!(b64_flags[ch] & K_VAL))
            break;
        acc = (acc << 6) | b64_val[ch];
        seen++;
        if (seen == 4) {
            dst[j++] = (acc >> 16) & 0xFF;
            dst[j++] = (acc >> 8) & 0xFF;
            dst[j++] = acc & 0xFF;
            seen = 0;
            acc = 0;
        }
    }

    if (seen != 0) {
        if (seen == 3) {
            dst[j++] = (acc >> 10) & 0xFF;
            dst[j++] = (acc >> 2) & 0xFF;
        } else if (seen == 2) {
            dst[j++] = (acc >> 4) & 0xFF;
        } else {
            *err = 1;
            return 0;
        }
        for (pad = 0; i < len; i++) {
            ch = (unsigned char)src[i];
            if (pad < 2 && ch == '=')
                pad++;
            else if (!(b64_flags[ch] & K_WS))
                break;
        }
        if (pad != 0 && seen + pad != 4) {
            *err = 1;
            return 0;
        }
    }

    *err = i < len;
    return j;
}

static JSValue js_btoa(JSContext *ctx, JSValueConst this_val,
                       int argc, JSValueConst *argv)
{
    const uint8_t *in8;
    uint8_t *tmp = NULL;
    uint8_t *outp;
    JSValue val, ret = JS_EXCEPTION;
    JSString *s, *ostr;
    size_t len, out_len, written;

    val = JS_ToString(ctx, argv[0]);
    if (unlikely(JS_IsException(val)))
        return JS_EXCEPTION;

    s = JS_VALUE_GET_STRING(val);
    len = (size_t)s->len;

    if (likely(!s->is_wide_char)) {
        in8 = (const uint8_t *)str8(s);
    } else {
        const uint16_t *src = str16(s);
        tmp = js_malloc(ctx, likely(len) ? len : 1);
        if (unlikely(!tmp))
            goto fail;
        for (size_t i = 0; i < len; i++) {
            uint32_t c = src[i];
            if (unlikely(c > 0xFF)) {
                JS_ThrowDOMException(ctx, "InvalidCharacterError",
                                     "String contains an invalid character");
                goto fail;
            }
            tmp[i] = (uint8_t)c;
        }
        in8 = tmp;
    }

    if (unlikely(len > (SIZE_MAX - 2) / 3)) {
        JS_ThrowRangeError(ctx, "input too large");
        goto fail;
    }
    out_len = 4 * ((len + 2) / 3);
    if (unlikely(out_len > JS_STRING_LEN_MAX)) {
        JS_ThrowRangeError(ctx, "output too large");
        goto fail;
    }

    ostr = js_alloc_string(ctx, out_len, 0);
    if (unlikely(!ostr))
        goto fail;

    outp = str8(ostr);
    written = b64_encode(in8, len, (char *)outp, b64_enc);
    outp[written] = '\0';
    ostr->len = out_len;
    ret = JS_MKPTR(JS_TAG_STRING, ostr);
fail:
    if (tmp)
        js_free(ctx, tmp);
    JS_FreeValue(ctx, val);
    return ret;
}

static JSValue js_atob(JSContext *ctx, JSValueConst this_val,
                       int argc, JSValueConst *argv)
{
    const uint8_t *in;
    uint8_t *tmp = NULL, *outp;
    JSValue val, ret = JS_EXCEPTION;
    JSString *s, *ostr;
    size_t slen, out_cap, out_len;
    int err;

    val = JS_ToString(ctx, argv[0]);
    if (unlikely(JS_IsException(val)))
        return JS_EXCEPTION;

    s = JS_VALUE_GET_STRING(val);
    slen = (size_t)s->len;

    if (likely(!s->is_wide_char)) {
        const uint8_t *p = (const uint8_t *)str8(s);
        for (size_t i = 0; i < slen; i++) {
            if (unlikely(p[i] & 0x80)) {
                JS_ThrowDOMException(ctx, "InvalidCharacterError",
                    "The string to be decoded is not correctly encoded");
                goto fail;
            }
        }
        in = p;
    } else {
        const uint16_t *src = str16(s);
        tmp = js_malloc(ctx, likely(slen) ? slen : 1);
        if (unlikely(!tmp))
            goto fail;
        for (size_t i = 0; i < slen; i++) {
            if (unlikely(src[i] > 0x7F)) {
                JS_ThrowDOMException(ctx, "InvalidCharacterError",
                    "The string to be decoded is not correctly encoded");
                goto fail;
            }
            tmp[i] = (uint8_t)src[i];
        }
        in = tmp;
    }

    if (unlikely(slen > (SIZE_MAX / 3) * 4)) {
        JS_ThrowRangeError(ctx, "input too large");
        goto fail;
    }
    out_cap = (slen / 4) * 3 + 3;
    if (unlikely(out_cap > JS_STRING_LEN_MAX)) {
        JS_ThrowRangeError(ctx, "output too large");
        goto fail;
    }

    ostr = js_alloc_string(ctx, out_cap, 0);
    if (unlikely(!ostr))
        goto fail;

    outp = str8(ostr);
    err = 0;
    out_len = b64_decode((const char *)in, slen, outp, &err);

    if (unlikely(err)) {
        js_free_string(ctx->rt, ostr);
        JS_ThrowDOMException(ctx, "InvalidCharacterError",
            "The string to be decoded is not correctly encoded");
        goto fail;
    }
    outp[out_len] = '\0';
    ostr->len = out_len;
    ret = JS_MKPTR(JS_TAG_STRING, ostr);
fail:
    if (tmp)
        js_free(ctx, tmp);
    JS_FreeValue(ctx, val);
    return ret;
}

static const JSCFunctionListEntry js_base64_funcs[] = {
    JS_CFUNC_DEF("btoa", 1, js_btoa),
    JS_CFUNC_DEF("atob", 1, js_atob),
};


/* Uint8Array base64/hex (tc39 proposal-arraybuffer-base64) */

enum {
    B64_ALPHABET_BASE64 = 0,
    B64_ALPHABET_BASE64URL = 1,
};

enum {
    B64_LAST_LOOSE = 0,
    B64_LAST_STRICT = 1,
    B64_LAST_STOP_BEFORE_PARTIAL = 2,
};


static size_t b64_skip_ws(const char *src, size_t len, size_t index,
                          const char *flags)
{
    while (index < len && (flags[(unsigned char)src[index]] & K_WS))
        index++;
    return index;
}

/* Implements the FromBase64 abstract operation.
   src/src_len: the input string (must be ASCII/latin1)
   dst/max_len: output buffer
   flags: b64_flags or b64_flags_url (selects valid characters)
   last_chunk: B64_LAST_LOOSE, B64_LAST_STRICT, or B64_LAST_STOP_BEFORE_PARTIAL
   *p_read: set to number of input characters consumed
   *p_err: set to 1 on error, 0 on success
   Returns: number of bytes written to dst */
static size_t from_base64(const char *src, size_t src_len,
                          uint8_t *dst, size_t max_len,
                          const char *flags, int last_chunk,
                          size_t *p_read, int *p_err)
{
    size_t read = 0, written = 0;
    uint32_t acc = 0;
    int seen = 0;
    size_t index = 0;

    *p_err = 0;

    if (max_len == 0) {
        *p_read = 0;
        return 0;
    }

    /* Fast path: decode complete groups of 4 valid characters.
       Breaks out on whitespace, padding, invalid chars, or capacity. */
    while (index + 4 <= src_len && written + 3 <= max_len) {
        uint8_t f = flags[(unsigned char)src[index]]
                  & flags[(unsigned char)src[index + 1]]
                  & flags[(unsigned char)src[index + 2]]
                  & flags[(unsigned char)src[index + 3]];
        if (!(f & K_VAL))
            break;
        uint32_t v = ((uint32_t)b64_val[(unsigned char)src[index]] << 18)
                   | ((uint32_t)b64_val[(unsigned char)src[index + 1]] << 12)
                   | ((uint32_t)b64_val[(unsigned char)src[index + 2]] << 6)
                   | (uint32_t)b64_val[(unsigned char)src[index + 3]];
        dst[written]     = (uint8_t)(v >> 16);
        dst[written + 1] = (uint8_t)(v >> 8);
        dst[written + 2] = (uint8_t)(v);
        written += 3;
        index += 4;
    }
    read = index;

    if (written >= max_len) {
        *p_read = read;
        return written;
    }

    /* Slow path: handle whitespace, padding, partial groups, capacity. */
    for (;;) {
        index = b64_skip_ws(src, src_len, index, flags);

        if (index == src_len) {
            if (seen > 0) {
                if (last_chunk == B64_LAST_STOP_BEFORE_PARTIAL) {
                    *p_read = read;
                    return written;
                }
                if (last_chunk == B64_LAST_STRICT) {
                    *p_err = 1;
                    return 0;
                }
                /* loose */
                if (seen == 1) {
                    *p_err = 1;
                    return 0;
                }
                goto decode_partial;
            }
            *p_read = src_len;
            return written;
        }

        unsigned char ch = src[index++];

        if (ch == '=') {
            if (seen < 2) {
                *p_err = 1;
                return 0;
            }
            index = b64_skip_ws(src, src_len, index, flags);
            if (seen == 2) {
                if (index == src_len) {
                    if (last_chunk == B64_LAST_STOP_BEFORE_PARTIAL) {
                        *p_read = read;
                        return written;
                    }
                    *p_err = 1;
                    return 0;
                }
                if (src[index] == '=') {
                    index++;
                    index = b64_skip_ws(src, src_len, index, flags);
                } else {
                    *p_err = 1;
                    return 0;
                }
            }
            /* After padding, only whitespace is allowed */
            if (index != src_len) {
                *p_err = 1;
                return 0;
            }
            if (last_chunk == B64_LAST_STRICT) {
                uint32_t mask = (seen == 2) ? 0xF : 0x3;
                if (acc & mask) {
                    *p_err = 1;
                    return 0;
                }
            }
            goto decode_partial;
        }

        if (!(flags[ch] & K_VAL)) {
            *p_err = 1;
            return 0;
        }

        /* Check remaining capacity before committing to this group */
        {
            size_t remaining = max_len - written;
            if ((remaining == 1 && seen == 2) ||
                    (remaining == 2 && seen == 3)) {
                *p_read = read;
                return written;
            }
        }

        acc = (acc << 6) | b64_val[ch];
        seen++;

        if (seen == 4) {
            dst[written]     = (uint8_t)(acc >> 16);
            dst[written + 1] = (uint8_t)(acc >> 8);
            dst[written + 2] = (uint8_t)(acc);
            written += 3;
            acc = 0;
            seen = 0;
            read = index;
            if (written >= max_len) {
                *p_read = read;
                return written;
            }
        }
    }

decode_partial:
    if (seen == 2) {
        dst[written++] = (uint8_t)(acc >> 4);
    } else if (seen == 3) {
        dst[written]     = (uint8_t)(acc >> 10);
        dst[written + 1] = (uint8_t)(acc >> 2);
        written += 2;
    }
    *p_read = src_len;
    return written;
}

/* Hex helpers */
static const char u8a_hex_digits[] = "0123456789abcdef";

static int u8a_hex_nibble(unsigned char ch)
{
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
    return -1;
}

static size_t u8a_hex_encode(const uint8_t *src, size_t len, char *dst)
{
    for (size_t i = 0; i < len; i++) {
        dst[i * 2]     = u8a_hex_digits[src[i] >> 4];
        dst[i * 2 + 1] = u8a_hex_digits[src[i] & 0xF];
    }
    return len * 2;
}

/* Decode hex string to bytes.
   Returns bytes written. Sets *p_read to chars consumed, *p_err on error. */
static size_t u8a_hex_decode(const char *src, size_t src_len,
                             uint8_t *dst, size_t max_len,
                             size_t *p_read, int *p_err)
{
    size_t written = 0, i = 0;
    *p_err = 0;

    if (src_len & 1) {
        *p_err = 1;
        return 0;
    }

    while (i < src_len && written < max_len) {
        int hi = u8a_hex_nibble(src[i]);
        int lo = u8a_hex_nibble(src[i + 1]);
        if (hi < 0 || lo < 0) {
            *p_err = 1;
            return 0;
        }
        dst[written++] = (uint8_t)((hi << 4) | lo);
        i += 2;
    }

    *p_read = i;
    return written;
}

/* Validate that this_val is a Uint8Array (type check only, no detach check).
   Returns the JSObject pointer or NULL on error (throws). */
static JSObject *check_uint8array(JSContext *ctx, JSValueConst this_val)
{
    JSObject *p;

    if (JS_VALUE_GET_TAG(this_val) != JS_TAG_OBJECT)
        goto fail;
    p = JS_VALUE_GET_OBJ(this_val);
    if (p->class_id != JS_CLASS_UINT8_ARRAY)
        goto fail;
    return p;
fail:
    JS_ThrowTypeError(ctx, "not a Uint8Array");
    return NULL;
}

/* Get the data pointer and length of a Uint8Array, checking for detached
   buffers. Must be called after options are read (per spec ordering).
   Returns 0 on success, -1 on error (throws). */
static int get_uint8array_bytes(JSContext *ctx, JSObject *p,
                                uint8_t **pdata, size_t *plen)
{
    if (typed_array_is_oob(p)) {
        JS_ThrowTypeErrorArrayBufferOOB(ctx);
        return -1;
    }
    *pdata = p->u.array.u.uint8_ptr;
    *plen = p->u.array.count;
    return 0;
}

/* Validate options is undefined or an object (GetOptionsObject).
   Returns 0 on success, -1 on error (throws). */
static int check_options_object(JSContext *ctx, JSValueConst options)
{
    if (JS_IsUndefined(options))
        return 0;
    if (!JS_IsObject(options)) {
        JS_ThrowTypeError(ctx, "options must be an object");
        return -1;
    }
    return 0;
}

/* Parse the 'alphabet' option from an options object.
   Returns B64_ALPHABET_BASE64 or B64_ALPHABET_BASE64URL, or -1 on error. */
static int parse_alphabet_option(JSContext *ctx, JSValueConst options)
{
    JSValue val;
    const char *str;
    int ret;

    if (JS_IsUndefined(options))
        return B64_ALPHABET_BASE64;

    val = JS_GetPropertyStr(ctx, options, "alphabet");
    if (JS_IsException(val))
        return -1;
    if (JS_IsUndefined(val))
        return B64_ALPHABET_BASE64;
    if (!JS_IsString(val)) {
        JS_FreeValue(ctx, val);
        JS_ThrowTypeError(ctx, "expected string for alphabet");
        return -1;
    }

    str = JS_ToCString(ctx, val);
    JS_FreeValue(ctx, val);
    if (!str)
        return -1;

    if (!strcmp(str, "base64"))
        ret = B64_ALPHABET_BASE64;
    else if (!strcmp(str, "base64url"))
        ret = B64_ALPHABET_BASE64URL;
    else {
        JS_ThrowTypeError(ctx, "invalid alphabet");
        ret = -1;
    }
    JS_FreeCString(ctx, str);
    return ret;
}

/* Parse the 'lastChunkHandling' option. Returns mode or -1 on error. */
static int parse_last_chunk_option(JSContext *ctx, JSValueConst options)
{
    JSValue val;
    const char *str;
    int ret;

    if (JS_IsUndefined(options))
        return B64_LAST_LOOSE;

    val = JS_GetPropertyStr(ctx, options, "lastChunkHandling");
    if (JS_IsException(val))
        return -1;
    if (JS_IsUndefined(val))
        return B64_LAST_LOOSE;
    if (!JS_IsString(val)) {
        JS_FreeValue(ctx, val);
        JS_ThrowTypeError(ctx, "expected string for lastChunkHandling");
        return -1;
    }

    str = JS_ToCString(ctx, val);
    JS_FreeValue(ctx, val);
    if (!str)
        return -1;

    if (!strcmp(str, "loose"))
        ret = B64_LAST_LOOSE;
    else if (!strcmp(str, "strict"))
        ret = B64_LAST_STRICT;
    else if (!strcmp(str, "stop-before-partial"))
        ret = B64_LAST_STOP_BEFORE_PARTIAL;
    else {
        JS_ThrowTypeError(ctx, "invalid lastChunkHandling option");
        ret = -1;
    }
    JS_FreeCString(ctx, str);
    return ret;
}

/* Uint8Array.prototype.toBase64([options]) */
static JSValue js_uint8array_to_base64(JSContext *ctx, JSValueConst this_val,
                                       int argc, JSValueConst *argv)
{
    uint8_t *data;
    size_t len;
    JSValue options;
    JSObject *p;
    int alphabet, omit_padding;
    size_t out_len, written;
    JSString *ostr;
    char *dst;

    p = check_uint8array(ctx, this_val);
    if (!p)
        return JS_EXCEPTION;

    options = argc > 0 ? unsafe_unconst(argv[0]) : JS_UNDEFINED;
    if (check_options_object(ctx, options))
        return JS_EXCEPTION;
    alphabet = parse_alphabet_option(ctx, options);
    if (alphabet < 0)
        return JS_EXCEPTION;

    omit_padding = 0;
    if (!JS_IsUndefined(options)) {
        JSValue op_val = JS_GetPropertyStr(ctx, options, "omitPadding");
        if (JS_IsException(op_val))
            return JS_EXCEPTION;
        omit_padding = JS_ToBool(ctx, op_val);
        JS_FreeValue(ctx, op_val);
    }

    if (get_uint8array_bytes(ctx, p, &data, &len))
        return JS_EXCEPTION;

    out_len = 4 * ((len + 2) / 3);

    if (unlikely(out_len > JS_STRING_LEN_MAX))
        return JS_ThrowRangeError(ctx, "output too large");

    ostr = js_alloc_string(ctx, out_len, 0);
    if (!ostr)
        return JS_EXCEPTION;

    dst = (char *)str8(ostr);
    written = b64_encode(data, len, dst,
                         alphabet == B64_ALPHABET_BASE64URL ? b64url_enc : b64_enc);
    if (omit_padding) {
        while (written > 0 && dst[written - 1] == '=')
            written--;
    }
    dst[written] = '\0';

    ostr->len = written;
    return JS_MKPTR(JS_TAG_STRING, ostr);
}

/* Uint8Array.prototype.toHex() */
static JSValue js_uint8array_to_hex(JSContext *ctx, JSValueConst this_val,
                                    int argc, JSValueConst *argv)
{
    uint8_t *data;
    size_t len, out_len;
    JSObject *p;
    JSString *ostr;

    p = check_uint8array(ctx, this_val);
    if (!p)
        return JS_EXCEPTION;
    if (get_uint8array_bytes(ctx, p, &data, &len))
        return JS_EXCEPTION;

    out_len = len * 2;
    if (unlikely(out_len > JS_STRING_LEN_MAX))
        return JS_ThrowRangeError(ctx, "output too large");

    ostr = js_alloc_string(ctx, out_len, 0);
    if (!ostr)
        return JS_EXCEPTION;

    u8a_hex_encode(data, len, (char *)str8(ostr));
    str8(ostr)[out_len] = '\0';
    return JS_MKPTR(JS_TAG_STRING, ostr);
}

/* Uint8Array.fromBase64(string[, options]) */
static JSValue js_uint8array_from_base64(JSContext *ctx, JSValueConst this_val,
                                         int argc, JSValueConst *argv)
{
    const char *str;
    size_t str_len, read_pos, decoded_len, out_cap;
    int alphabet, last_chunk, err;
    uint8_t *buf;
    JSValue result, options;

    if (!JS_IsString(argv[0]))
        return JS_ThrowTypeError(ctx, "expected string");

    str = JS_ToCStringLen(ctx, &str_len, argv[0]);
    if (!str)
        return JS_EXCEPTION;

    options = argc > 1 ? unsafe_unconst(argv[1]) : JS_UNDEFINED;
    if (check_options_object(ctx, options)) {
        JS_FreeCString(ctx, str);
        return JS_EXCEPTION;
    }
    alphabet = parse_alphabet_option(ctx, options);
    if (alphabet < 0) {
        JS_FreeCString(ctx, str);
        return JS_EXCEPTION;
    }
    last_chunk = parse_last_chunk_option(ctx, options);
    if (last_chunk < 0) {
        JS_FreeCString(ctx, str);
        return JS_EXCEPTION;
    }

    out_cap = (str_len / 4) * 3 + 3;
    buf = js_malloc(ctx, out_cap ? out_cap : 1);
    if (!buf) {
        JS_FreeCString(ctx, str);
        return JS_EXCEPTION;
    }

    decoded_len = from_base64(str, str_len, buf, out_cap,
                              alphabet == B64_ALPHABET_BASE64URL
                                  ? b64_flags_url : b64_flags,
                              last_chunk, &read_pos, &err);
    JS_FreeCString(ctx, str);

    if (err) {
        js_free(ctx, buf);
        return JS_ThrowSyntaxError(ctx, "invalid base64 string");
    }

    result = JS_NewUint8ArrayCopy(ctx, buf, decoded_len);
    js_free(ctx, buf);
    return result;
}

/* Uint8Array.fromHex(string) */
static JSValue js_uint8array_from_hex(JSContext *ctx, JSValueConst this_val,
                                      int argc, JSValueConst *argv)
{
    const char *str;
    size_t str_len, read_pos, decoded_len, out_cap;
    int err;
    uint8_t *buf;
    JSValue result;

    if (!JS_IsString(argv[0]))
        return JS_ThrowTypeError(ctx, "expected string");

    str = JS_ToCStringLen(ctx, &str_len, argv[0]);
    if (!str)
        return JS_EXCEPTION;

    out_cap = str_len / 2 + 1;
    buf = js_malloc(ctx, out_cap ? out_cap : 1);
    if (!buf) {
        JS_FreeCString(ctx, str);
        return JS_EXCEPTION;
    }

    decoded_len = u8a_hex_decode(str, str_len, buf, out_cap, &read_pos, &err);
    JS_FreeCString(ctx, str);

    if (err) {
        js_free(ctx, buf);
        return JS_ThrowSyntaxError(ctx, "invalid hex string");
    }

    result = JS_NewUint8ArrayCopy(ctx, buf, decoded_len);
    js_free(ctx, buf);
    return result;
}

/* Return a { read, written } result object */
static JSValue js_make_read_written(JSContext *ctx, size_t read, size_t written)
{
    JSValue obj = JS_NewObject(ctx);
    if (JS_IsException(obj))
        return JS_EXCEPTION;
    if (JS_DefinePropertyValueStr(ctx, obj, "read",
            js_uint32(read), JS_PROP_C_W_E) < 0)
        goto fail;
    if (JS_DefinePropertyValueStr(ctx, obj, "written",
            js_uint32(written), JS_PROP_C_W_E) < 0)
        goto fail;
    return obj;
fail:
    JS_FreeValue(ctx, obj);
    return JS_EXCEPTION;
}

/* Uint8Array.prototype.setFromBase64(string[, options]) */
static JSValue js_uint8array_set_from_base64(JSContext *ctx,
                                             JSValueConst this_val,
                                             int argc, JSValueConst *argv)
{
    uint8_t *data;
    size_t len;
    const char *str;
    size_t str_len, read_pos, decoded_len;
    JSObject *p;
    int alphabet, last_chunk, err;
    JSValue options;

    p = check_uint8array(ctx, this_val);
    if (!p)
        return JS_EXCEPTION;

    if (typed_array_is_immutable(p))
        return JS_ThrowTypeErrorImmutableArrayBuffer(ctx);

    if (!JS_IsString(argv[0]))
        return JS_ThrowTypeError(ctx, "expected string");

    str = JS_ToCStringLen(ctx, &str_len, argv[0]);
    if (!str)
        return JS_EXCEPTION;

    options = argc > 1 ? unsafe_unconst(argv[1]) : JS_UNDEFINED;
    if (check_options_object(ctx, options)) {
        JS_FreeCString(ctx, str);
        return JS_EXCEPTION;
    }
    alphabet = parse_alphabet_option(ctx, options);
    if (alphabet < 0) {
        JS_FreeCString(ctx, str);
        return JS_EXCEPTION;
    }
    last_chunk = parse_last_chunk_option(ctx, options);
    if (last_chunk < 0) {
        JS_FreeCString(ctx, str);
        return JS_EXCEPTION;
    }

    if (get_uint8array_bytes(ctx, p, &data, &len)) {
        JS_FreeCString(ctx, str);
        return JS_EXCEPTION;
    }

    decoded_len = from_base64(str, str_len, data, len,
                              alphabet == B64_ALPHABET_BASE64URL
                                  ? b64_flags_url : b64_flags,
                              last_chunk, &read_pos, &err);
    JS_FreeCString(ctx, str);

    if (err)
        return JS_ThrowSyntaxError(ctx, "invalid base64 string");

    return js_make_read_written(ctx, read_pos, decoded_len);
}

/* Uint8Array.prototype.setFromHex(string) */
static JSValue js_uint8array_set_from_hex(JSContext *ctx,
                                          JSValueConst this_val,
                                          int argc, JSValueConst *argv)
{
    uint8_t *data;
    size_t len;
    const char *str;
    size_t str_len, read_pos, decoded_len;
    JSObject *p;
    int err;

    p = check_uint8array(ctx, this_val);
    if (!p)
        return JS_EXCEPTION;

    if (typed_array_is_immutable(p))
        return JS_ThrowTypeErrorImmutableArrayBuffer(ctx);

    if (!JS_IsString(argv[0]))
        return JS_ThrowTypeError(ctx, "expected string");

    str = JS_ToCStringLen(ctx, &str_len, argv[0]);
    if (!str)
        return JS_EXCEPTION;

    if (get_uint8array_bytes(ctx, p, &data, &len)) {
        JS_FreeCString(ctx, str);
        return JS_EXCEPTION;
    }

    decoded_len = u8a_hex_decode(str, str_len, data, len, &read_pos, &err);
    JS_FreeCString(ctx, str);

    if (err)
        return JS_ThrowSyntaxError(ctx, "invalid hex string");

    return js_make_read_written(ctx, read_pos, decoded_len);
}

static const JSCFunctionListEntry js_uint8array_proto_funcs[] = {
    JS_CFUNC_DEF("toBase64", 0, js_uint8array_to_base64),
    JS_CFUNC_DEF("toHex", 0, js_uint8array_to_hex),
    JS_CFUNC_DEF("setFromBase64", 1, js_uint8array_set_from_base64),
    JS_CFUNC_DEF("setFromHex", 1, js_uint8array_set_from_hex),
};

static const JSCFunctionListEntry js_uint8array_funcs[] = {
    JS_CFUNC_DEF("fromBase64", 1, js_uint8array_from_base64),
    JS_CFUNC_DEF("fromHex", 1, js_uint8array_from_hex),
};

static int js_uint8array_funcs_init(JSContext *ctx)
{
    JSValue ctor, proto;

    ctor = JS_GetProperty(ctx, ctx->global_obj, JS_ATOM_Uint8Array);
    if (JS_IsException(ctor))
        return -1;
    proto = JS_GetProperty(ctx, ctor, JS_ATOM_prototype);
    if (JS_IsException(proto)) {
        JS_FreeValue(ctx, ctor);
        return -1;
    }
    JS_SetPropertyFunctionList(ctx, proto,
                               js_uint8array_proto_funcs,
                               countof(js_uint8array_proto_funcs));
    JS_FreeValue(ctx, proto);
    JS_SetPropertyFunctionList(ctx, ctor,
                               js_uint8array_funcs,
                               countof(js_uint8array_funcs));
    JS_FreeValue(ctx, ctor);
    return 0;
}

int JS_AddIntrinsicAToB(JSContext *ctx)
{
    if (!JS_IsRegisteredClass(ctx->rt, JS_CLASS_DOM_EXCEPTION)) {
        if (JS_AddIntrinsicDOMException(ctx))
            return -1;
    }
    JS_SetPropertyFunctionList(ctx, ctx->global_obj,
                               js_base64_funcs, countof(js_base64_funcs));
    return 0;
}

bool JS_DetectModule(const char *input, size_t input_len)
{
#ifndef QJS_DISABLE_PARSER
    JSRuntime *rt;
    JSContext *ctx;
    JSValue val;
    bool is_module;

    is_module = true;
    rt = JS_NewRuntime();
    if (!rt)
        return false;
    ctx = JS_NewContextRaw(rt);
    if (!ctx) {
        JS_FreeRuntime(rt);
        return false;
    }
    JS_AddIntrinsicRegExpCompiler(ctx); // otherwise regexp literals don't parse
    val = __JS_EvalInternal(ctx, JS_UNDEFINED, input, input_len, "<unnamed>", 1,
                            JS_EVAL_TYPE_MODULE|JS_EVAL_FLAG_COMPILE_ONLY, -1);
    if (JS_IsException(val)) {
        const char *msg = JS_ToCString(ctx, rt->current_exception);
        // gruesome hack to recognize exceptions from import statements;
        // necessary because we don't pass in a module loader
        is_module = !!strstr(msg, "ReferenceError: could not load module");
        JS_FreeCString(ctx, msg);
    }
    JS_FreeValue(ctx, val);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    return is_module;
#else
    return false;
#endif // QJS_DISABLE_PARSER
}

uintptr_t js_std_cmd(int cmd, ...) {
    JSContext *ctx;
    JSRuntime *rt;
    JSValue *pv;
    uintptr_t rv;
    va_list ap;

    rv = 0;
    va_start(ap, cmd);
    switch (cmd) {
    case 0: // GetOpaque
        rt = va_arg(ap, JSRuntime *);
        rv = (uintptr_t)rt->libc_opaque;
        break;
    case 1: // SetOpaque
        rt = va_arg(ap, JSRuntime *);
        rt->libc_opaque = va_arg(ap, void *);
        break;
    case 2: // ErrorBackTrace
        ctx = va_arg(ap, JSContext *);
        pv = va_arg(ap, JSValue *);
        *pv = ctx->error_back_trace;
        ctx->error_back_trace = JS_UNDEFINED;
        break;
    case 3: // GetStringKind
        ctx = va_arg(ap, JSContext *);
        pv = va_arg(ap, JSValue *);
        rv = -1;
        if (JS_IsString(*pv))
            rv = JS_VALUE_GET_STRING(*pv)->kind;
        break;
    case 4: // GetShapeHashCount
        rt = va_arg(ap, JSRuntime *);
        rv = rt->shape_hash_count;
        break;
    case 5: // GetInterruptHandler
        rt = va_arg(ap, JSRuntime *);
        rv = (uintptr_t)rt->interrupt_handler;
        break;
    case 6: // GetInterruptOpaque
        rt = va_arg(ap, JSRuntime *);
        rv = (uintptr_t)rt->interrupt_opaque;
        break;
    default:
        rv = -1;
    }
    va_end(ap);

    return rv;
}

#undef malloc
#undef free
#undef realloc
