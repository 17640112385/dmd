/**
 * Handles target-specific parameters
 *
 * In order to allow for cross compilation, when the compiler produces a binary
 * for a different platform than it is running on, target information needs
 * to be abstracted. This is done in this module, primarily through `Target`.
 *
 * Note:
 * While DMD itself does not support cross-compilation, GDC and LDC do.
 * Hence, this module is (sometimes heavily) modified by them,
 * and contributors should review how their changes affect them.
 *
 * See_Also:
 * - $(LINK2 https://wiki.osdev.org/Target_Triplet, Target Triplets)
 * - $(LINK2 https://github.com/ldc-developers/ldc, LDC repository)
 * - $(LINK2 https://github.com/D-Programming-GDC/gcc, GDC repository)
 *
 * Copyright:   Copyright (C) 1999-2020 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/target.d, _target.d)
 * Documentation:  https://dlang.org/phobos/dmd_target.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/target.d
 */

module dmd.target;

import dmd.argtypes;
import core.stdc.string : strlen;
import dmd.cppmangle;
import dmd.cppmanglewin;
import dmd.dclass;
import dmd.declaration;
import dmd.dscope;
import dmd.dstruct;
import dmd.dsymbol;
import dmd.expression;
import dmd.func;
import dmd.globals;
import dmd.id;
import dmd.identifier;
import dmd.mtype;
import dmd.root.rmem;
import dmd.typesem;
import dmd.tokens : TOK;
import dmd.root.ctfloat;
import dmd.root.outbuffer;
import dmd.root.string : toDString;

////////////////////////////////////////////////////////////////////////////////
/**
 * Describes a back-end target. At present it is incomplete, but in the future
 * it should grow to contain most or all target machine and target O/S specific
 * information.
 *
 * In many cases, calls to sizeof() can't be used directly for getting data type
 * sizes since cross compiling is supported and would end up using the host
 * sizes rather than the target sizes.
 */
extern (C++) struct Target
{
    // D ABI
    uint ptrsize;             /// size of a pointer in bytes
    uint realsize;            /// size a real consumes in memory
    uint realpad;             /// padding added to the CPU real size to bring it up to realsize
    uint realalignsize;       /// alignment for reals
    uint classinfosize;       /// size of `ClassInfo`
    ulong maxStaticDataSize;  /// maximum size of static data

    /// C ABI
    TargetC c;

    /// C++ ABI
    TargetCPP cpp;

    /// Objective-C ABI
    TargetObjC objc;

    /**
     * Values representing all properties for floating point types
     */
    extern (C++) struct FPTypeProperties(T)
    {
        real_t max;                         /// largest representable value that's not infinity
        real_t min_normal;                  /// smallest representable normalized value that's not 0
        real_t nan;                         /// NaN value
        real_t infinity;                    /// infinity value
        real_t epsilon;                     /// smallest increment to the value 1

        d_int64 dig = T.dig;                /// number of decimal digits of precision
        d_int64 mant_dig = T.mant_dig;      /// number of bits in mantissa
        d_int64 max_exp = T.max_exp;        /// maximum int value such that 2$(SUPERSCRIPT `max_exp-1`) is representable
        d_int64 min_exp = T.min_exp;        /// minimum int value such that 2$(SUPERSCRIPT `min_exp-1`) is representable as a normalized value
        d_int64 max_10_exp = T.max_10_exp;  /// maximum int value such that 10$(SUPERSCRIPT `max_10_exp` is representable)
        d_int64 min_10_exp = T.min_10_exp;  /// minimum int value such that 10$(SUPERSCRIPT `min_10_exp`) is representable as a normalized value

        extern (D) void initialize()
        {
            max = T.max;
            min_normal = T.min_normal;
            nan = T.nan;
            infinity = T.infinity;
            epsilon = T.epsilon;
        }
    }

    FPTypeProperties!float FloatProperties;     ///
    FPTypeProperties!double DoubleProperties;   ///
    FPTypeProperties!real_t RealProperties;     ///

    private Type tvalist; // cached lazy result of va_listType()

    /**
     * Initialize the Target
     */
    extern (C++) void _init(ref const Param params)
    {
        FloatProperties.initialize();
        DoubleProperties.initialize();
        RealProperties.initialize();

        // These have default values for 32 bit code, they get
        // adjusted for 64 bit code.
        ptrsize = 4;
        classinfosize = 0x4C; // 76

        /* gcc uses int.max for 32 bit compilations, and long.max for 64 bit ones.
         * Set to int.max for both, because the rest of the compiler cannot handle
         * 2^64-1 without some pervasive rework. The trouble is that much of the
         * front and back end uses 32 bit ints for sizes and offsets. Since C++
         * silently truncates 64 bit ints to 32, finding all these dependencies will be a problem.
         */
        maxStaticDataSize = int.max;

        if (params.isLP64)
        {
            ptrsize = 8;
            classinfosize = 0x98; // 152
        }
        if (params.isLinux || params.isFreeBSD || params.isOpenBSD || params.isDragonFlyBSD || params.isSolaris)
        {
            realsize = 12;
            realpad = 2;
            realalignsize = 4;
        }
        else if (params.isOSX)
        {
            realsize = 16;
            realpad = 6;
            realalignsize = 16;
        }
        else if (params.isWindows)
        {
            realsize = 10;
            realpad = 0;
            realalignsize = 2;
            if (ptrsize == 4)
            {
                /* Optlink cannot deal with individual data chunks
                 * larger than 16Mb
                 */
                maxStaticDataSize = 0x100_0000;  // 16Mb
            }
        }
        else
            assert(0);
        if (params.is64bit)
        {
            if (params.isLinux || params.isFreeBSD || params.isDragonFlyBSD || params.isSolaris)
            {
                realsize = 16;
                realpad = 6;
                realalignsize = 16;
            }
        }

        c.initialize(params, this);
        cpp.initialize(params, this);
        objc.initialize(params, this);
    }

    /**
     * Deinitializes the global state of the compiler.
     *
     * This can be used to restore the state set by `_init` to its original
     * state.
     */
    void deinitialize()
    {
        this = this.init;
    }

    /**
     * Requested target memory alignment size of the given type.
     * Params:
     *      type = type to inspect
     * Returns:
     *      alignment in bytes
     */
    extern (C++) uint alignsize(Type type)
    {
        assert(type.isTypeBasic());
        switch (type.ty)
        {
        case Tfloat80:
        case Timaginary80:
        case Tcomplex80:
            return target.realalignsize;
        case Tcomplex32:
            if (global.params.isLinux || global.params.isOSX || global.params.isFreeBSD || global.params.isOpenBSD ||
                global.params.isDragonFlyBSD || global.params.isSolaris)
                return 4;
            break;
        case Tint64:
        case Tuns64:
        case Tfloat64:
        case Timaginary64:
        case Tcomplex64:
            if (global.params.isLinux || global.params.isOSX || global.params.isFreeBSD || global.params.isOpenBSD ||
                global.params.isDragonFlyBSD || global.params.isSolaris)
                return global.params.is64bit ? 8 : 4;
            break;
        default:
            break;
        }
        return cast(uint)type.size(Loc.initial);
    }

    /**
     * Requested target field alignment size of the given type.
     * Params:
     *      type = type to inspect
     * Returns:
     *      alignment in bytes
     */
    extern (C++) uint fieldalign(Type type)
    {
        const size = type.alignsize();

        if ((global.params.is64bit || global.params.isOSX) && (size == 16 || size == 32))
            return size;

        return (8 < size) ? 8 : size;
    }

    /**
     * Size of the target OS critical section.
     * Returns:
     *      size in bytes
     */
    extern (C++) uint critsecsize()
    {
        return c.criticalSectionSize;
    }

    /**
     * Type for the `va_list` type for the target; e.g., required for `_argptr`
     * declarations.
     * NOTE: For Posix/x86_64 this returns the type which will really
     * be used for passing an argument of type va_list.
     * Returns:
     *      `Type` that represents `va_list`.
     */
    extern (C++) Type va_listType(const ref Loc loc, Scope* sc)
    {
        if (tvalist)
            return tvalist;

        if (global.params.isWindows)
        {
            tvalist = Type.tchar.pointerTo();
        }
        else if (global.params.isLinux        || global.params.isFreeBSD || global.params.isOpenBSD ||
                 global.params.isDragonFlyBSD || global.params.isSolaris || global.params.isOSX)
        {
            if (global.params.is64bit)
            {
                tvalist = Pool!TypeIdentifier.make(Loc.initial, Identifier.idPool("__va_list_tag")).pointerTo();
                tvalist = typeSemantic(tvalist, loc, sc);
            }
            else
            {
                tvalist = Type.tchar.pointerTo();
            }
        }
        else
        {
            assert(0);
        }

        return tvalist;
    }

    /**
     * Checks whether the target supports a vector type.
     * Params:
     *      sz   = vector type size in bytes
     *      type = vector element type
     * Returns:
     *      0   vector type is supported,
     *      1   vector type is not supported on the target at all
     *      2   vector element type is not supported
     *      3   vector size is not supported
     */
    extern (C++) int isVectorTypeSupported(int sz, Type type)
    {
        if (!isXmmSupported())
            return 1; // not supported

        switch (type.ty)
        {
        case Tvoid:
        case Tint8:
        case Tuns8:
        case Tint16:
        case Tuns16:
        case Tint32:
        case Tuns32:
        case Tfloat32:
        case Tint64:
        case Tuns64:
        case Tfloat64:
            break;
        default:
            return 2; // wrong base type
        }

        // Whether a vector is really supported depends on the CPU being targeted.
        if (sz == 16)
        {
            final switch (type.ty)
            {
            case Tint32:
            case Tuns32:
            case Tfloat32:
                if (global.params.cpu < CPU.sse)
                    return 3; // no SSE vector support
                break;

            case Tvoid:
            case Tint8:
            case Tuns8:
            case Tint16:
            case Tuns16:
            case Tint64:
            case Tuns64:
            case Tfloat64:
                if (global.params.cpu < CPU.sse2)
                    return 3; // no SSE2 vector support
                break;
            }
        }
        else if (sz == 32)
        {
            if (global.params.cpu < CPU.avx)
                return 3; // no AVX vector support
        }
        else
            return 3; // wrong size

        return 0;
    }

    /**
     * Checks whether the target supports the given operation for vectors.
     * Params:
     *      type = target type of operation
     *      op   = the unary or binary op being done on the `type`
     *      t2   = type of second operand if `op` is a binary operation
     * Returns:
     *      true if the operation is supported or type is not a vector
     */
    extern (C++) bool isVectorOpSupported(Type type, ubyte op, Type t2 = null)
    {
        import dmd.tokens;

        if (type.ty != Tvector)
            return true; // not a vector op
        auto tvec = cast(TypeVector) type;
        const vecsize = cast(int)tvec.basetype.size();
        const elemty = cast(int)tvec.elementType().ty;

        // Only operations on these sizes are supported (see isVectorTypeSupported)
        if (vecsize != 16 && vecsize != 32)
            return false;

        bool supported = false;
        switch (op)
        {
        case TOK.uadd:
            // Expression is a no-op, supported everywhere.
            supported = tvec.isscalar();
            break;

        case TOK.negate:
            if (vecsize == 16)
            {
                // float[4] negate needs SSE support ({V}SUBPS)
                if (elemty == Tfloat32 && global.params.cpu >= CPU.sse)
                    supported = true;
                // double[2] negate needs SSE2 support ({V}SUBPD)
                else if (elemty == Tfloat64 && global.params.cpu >= CPU.sse2)
                    supported = true;
                // (u)byte[16]/short[8]/int[4]/long[2] negate needs SSE2 support ({V}PSUB[BWDQ])
                else if (tvec.isintegral() && global.params.cpu >= CPU.sse2)
                    supported = true;
            }
            else if (vecsize == 32)
            {
                // float[8]/double[4] negate needs AVX support (VSUBP[SD])
                if (tvec.isfloating() && global.params.cpu >= CPU.avx)
                    supported = true;
                // (u)byte[32]/short[16]/int[8]/long[4] negate needs AVX2 support (VPSUB[BWDQ])
                else if (tvec.isintegral() && global.params.cpu >= CPU.avx2)
                    supported = true;
            }
            break;

        case TOK.lessThan, TOK.greaterThan, TOK.lessOrEqual, TOK.greaterOrEqual, TOK.equal, TOK.notEqual, TOK.identity, TOK.notIdentity:
            supported = false;
            break;

        case TOK.leftShift, TOK.leftShiftAssign, TOK.rightShift, TOK.rightShiftAssign, TOK.unsignedRightShift, TOK.unsignedRightShiftAssign:
            supported = false;
            break;

        case TOK.add, TOK.addAssign, TOK.min, TOK.minAssign:
            if (vecsize == 16)
            {
                // float[4] add/sub needs SSE support ({V}ADDPS, {V}SUBPS)
                if (elemty == Tfloat32 && global.params.cpu >= CPU.sse)
                    supported = true;
                // double[2] add/sub needs SSE2 support ({V}ADDPD, {V}SUBPD)
                else if (elemty == Tfloat64 && global.params.cpu >= CPU.sse2)
                    supported = true;
                // (u)byte[16]/short[8]/int[4]/long[2] add/sub needs SSE2 support ({V}PADD[BWDQ], {V}PSUB[BWDQ])
                else if (tvec.isintegral() && global.params.cpu >= CPU.sse2)
                    supported = true;
            }
            else if (vecsize == 32)
            {
                // float[8]/double[4] add/sub needs AVX support (VADDP[SD], VSUBP[SD])
                if (tvec.isfloating() && global.params.cpu >= CPU.avx)
                    supported = true;
                // (u)byte[32]/short[16]/int[8]/long[4] add/sub needs AVX2 support (VPADD[BWDQ], VPSUB[BWDQ])
                else if (tvec.isintegral() && global.params.cpu >= CPU.avx2)
                    supported = true;
            }
            break;

        case TOK.mul, TOK.mulAssign:
            if (vecsize == 16)
            {
                // float[4] multiply needs SSE support ({V}MULPS)
                if (elemty == Tfloat32 && global.params.cpu >= CPU.sse)
                    supported = true;
                // double[2] multiply needs SSE2 support ({V}MULPD)
                else if (elemty == Tfloat64 && global.params.cpu >= CPU.sse2)
                    supported = true;
                // (u)short[8] multiply needs SSE2 support ({V}PMULLW)
                else if ((elemty == Tint16 || elemty == Tuns16) && global.params.cpu >= CPU.sse2)
                    supported = true;
                // (u)int[4] multiply needs SSE4.1 support ({V}PMULLD)
                else if ((elemty == Tint32 || elemty == Tuns32) && global.params.cpu >= CPU.sse4_1)
                    supported = true;
            }
            else if (vecsize == 32)
            {
                // float[8]/double[4] multiply needs AVX support (VMULP[SD])
                if (tvec.isfloating() && global.params.cpu >= CPU.avx)
                    supported = true;
                // (u)short[16] multiply needs AVX2 support (VPMULLW)
                else if ((elemty == Tint16 || elemty == Tuns16) && global.params.cpu >= CPU.avx2)
                    supported = true;
                // (u)int[8] multiply needs AVX2 support (VPMULLD)
                else if ((elemty == Tint32 || elemty == Tuns32) && global.params.cpu >= CPU.avx2)
                    supported = true;
            }
            break;

        case TOK.div, TOK.divAssign:
            if (vecsize == 16)
            {
                // float[4] divide needs SSE support ({V}DIVPS)
                if (elemty == Tfloat32 && global.params.cpu >= CPU.sse)
                    supported = true;
                // double[2] divide needs SSE2 support ({V}DIVPD)
                else if (elemty == Tfloat64 && global.params.cpu >= CPU.sse2)
                    supported = true;
            }
            else if (vecsize == 32)
            {
                // float[8]/double[4] multiply needs AVX support (VDIVP[SD])
                if (tvec.isfloating() && global.params.cpu >= CPU.avx)
                    supported = true;
            }
            break;

        case TOK.mod, TOK.modAssign:
            supported = false;
            break;

        case TOK.and, TOK.andAssign, TOK.or, TOK.orAssign, TOK.xor, TOK.xorAssign:
            // (u)byte[16]/short[8]/int[4]/long[2] bitwise ops needs SSE2 support ({V}PAND, {V}POR, {V}PXOR)
            if (vecsize == 16 && tvec.isintegral() && global.params.cpu >= CPU.sse2)
                supported = true;
            // (u)byte[32]/short[16]/int[8]/long[4] bitwise ops needs AVX2 support (VPAND, VPOR, VPXOR)
            else if (vecsize == 32 && tvec.isintegral() && global.params.cpu >= CPU.avx2)
                supported = true;
            break;

        case TOK.not:
            supported = false;
            break;

        case TOK.tilde:
            // (u)byte[16]/short[8]/int[4]/long[2] logical exclusive needs SSE2 support ({V}PXOR)
            if (vecsize == 16 && tvec.isintegral() && global.params.cpu >= CPU.sse2)
                supported = true;
            // (u)byte[32]/short[16]/int[8]/long[4] logical exclusive needs AVX2 support (VPXOR)
            else if (vecsize == 32 && tvec.isintegral() && global.params.cpu >= CPU.avx2)
                supported = true;
            break;

        case TOK.pow, TOK.powAssign:
            supported = false;
            break;

        default:
            // import std.stdio : stderr, writeln;
            // stderr.writeln(op);
            assert(0, "unhandled op " ~ Token.toString(cast(TOK)op));
        }
        return supported;
    }

    /**
     * Default system linkage for the target.
     * Returns:
     *      `LINK` to use for `extern(System)`
     */
    extern (C++) LINK systemLinkage()
    {
        return global.params.isWindows ? LINK.windows : LINK.c;
    }

    /**
     * Describes how an argument type is passed to a function on target.
     * Params:
     *      t = type to break down
     * Returns:
     *      tuple of types if type is passed in one or more registers
     *      empty tuple if type is always passed on the stack
     *      null if the type is a `void` or argtypes aren't supported by the target
     */
    extern (C++) TypeTuple toArgTypes(Type t)
    {
        if (global.params.is64bit && global.params.isWindows)
            return null;
        return .toArgTypes(t);
    }

    /**
     * Determine return style of function - whether in registers or
     * through a hidden pointer to the caller's stack.
     * Params:
     *   tf = function type to check
     *   needsThis = true if the function type is for a non-static member function
     * Returns:
     *   true if return value from function is on the stack
     */
    extern (C++) bool isReturnOnStack(TypeFunction tf, bool needsThis)
    {
        if (tf.isref)
        {
            //printf("  ref false\n");
            return false;                 // returns a pointer
        }

        Type tn = tf.next.toBasetype();
        //printf("tn = %s\n", tn.toChars());
        d_uns64 sz = tn.size();
        Type tns = tn;

        if (global.params.isWindows && global.params.is64bit)
        {
            // http://msdn.microsoft.com/en-us/library/7572ztz4.aspx
            if (tns.ty == Tcomplex32)
                return true;
            if (tns.isscalar())
                return false;

            tns = tns.baseElemOf();
            if (tns.ty == Tstruct)
            {
                StructDeclaration sd = (cast(TypeStruct)tns).sym;
                if (tf.linkage == LINK.cpp && needsThis)
                    return true;
                if (!sd.isPOD() || sz > 8)
                    return true;
                if (sd.fields.dim == 0)
                    return true;
            }
            if (sz <= 16 && !(sz & (sz - 1)))
                return false;
            return true;
        }
        else if (global.params.isWindows && global.params.mscoff)
        {
            Type tb = tns.baseElemOf();
            if (tb.ty == Tstruct)
            {
                if (tf.linkage == LINK.cpp && needsThis)
                    return true;
            }
        }

    Lagain:
        if (tns.ty == Tsarray)
        {
            tns = tns.baseElemOf();
            if (tns.ty != Tstruct)
            {
    L2:
                if (global.params.isLinux && tf.linkage != LINK.d && !global.params.is64bit)
                {
                                                    // 32 bit C/C++ structs always on stack
                }
                else
                {
                    switch (sz)
                    {
                        case 1:
                        case 2:
                        case 4:
                        case 8:
                            //printf("  sarray false\n");
                            return false; // return small structs in regs
                                                // (not 3 byte structs!)
                        default:
                            break;
                    }
                }
                //printf("  sarray true\n");
                return true;
            }
        }

        if (tns.ty == Tstruct)
        {
            StructDeclaration sd = (cast(TypeStruct)tns).sym;
            if (global.params.isLinux && tf.linkage != LINK.d && !global.params.is64bit)
            {
                //printf("  2 true\n");
                return true;            // 32 bit C/C++ structs always on stack
            }
            if (global.params.isWindows && tf.linkage == LINK.cpp && !global.params.is64bit &&
                     sd.isPOD() && sd.ctor)
            {
                // win32 returns otherwise POD structs with ctors via memory
                return true;
            }
            if (sd.numArgTypes() == 1)
            {
                tns = sd.argType(0);
                if (tns.ty != Tstruct)
                    goto L2;
                goto Lagain;
            }
            else if (global.params.is64bit && sd.numArgTypes() == 0)
                return true;
            else if (sd.isPOD())
            {
                switch (sz)
                {
                    case 1:
                    case 2:
                    case 4:
                    case 8:
                        //printf("  3 false\n");
                        return false;     // return small structs in regs
                                            // (not 3 byte structs!)
                    case 16:
                        if (!global.params.isWindows && global.params.is64bit)
                           return false;
                        break;

                    default:
                        break;
                }
            }
            //printf("  3 true\n");
            return true;
        }
        else if ((global.params.isLinux || global.params.isOSX ||
                  global.params.isFreeBSD || global.params.isSolaris ||
                  global.params.isDragonFlyBSD) &&
                 tf.linkage == LINK.c &&
                 tns.iscomplex())
        {
            if (tns.ty == Tcomplex32)
                return false;     // in EDX:EAX, not ST1:ST0
            else
                return true;
        }
        else
        {
            //assert(sz <= 16);
            //printf("  4 false\n");
            return false;
        }
    }

    /***
     * Determine the size a value of type `t` will be when it
     * is passed on the function parameter stack.
     * Params:
     *  loc = location to use for error messages
     *  t = type of parameter
     * Returns:
     *  size used on parameter stack
     */
    extern (C++) ulong parameterSize(const ref Loc loc, Type t)
    {
        if (!global.params.is64bit &&
            (global.params.isFreeBSD || global.params.isOSX))
        {
            /* These platforms use clang, which regards a struct
             * with size 0 as being of size 0 on the parameter stack,
             * even while sizeof(struct) is 1.
             * It's an ABI incompatibility with gcc.
             */
            if (t.ty == Tstruct)
            {
                auto ts = cast(TypeStruct)t;
                if (ts.sym.hasNoFields)
                    return 0;
            }
        }
        const sz = t.size(loc);
        return global.params.is64bit ? (sz + 7) & ~7 : (sz + 3) & ~3;
    }

    // this guarantees `getTargetInfo` and `allTargetInfos` remain in sync
    private enum TargetInfoKeys
    {
        cppRuntimeLibrary,
        cppStd,
        floatAbi,
        objectFormat,
    }

    /**
     * Get targetInfo by key
     * Params:
     *  name = name of targetInfo to get
     *  loc = location to use for error messages
     * Returns:
     *  Expression for the requested targetInfo
     */
    extern (C++) Expression getTargetInfo(const(char)* name, const ref Loc loc)
    {
        StringExp stringExp(const(char)[] sval)
        {
            return new StringExp(loc, sval);
        }

        switch (name.toDString) with (TargetInfoKeys)
        {
            case objectFormat.stringof:
                if (global.params.isWindows)
                    return stringExp(global.params.mscoff ? "coff" : "omf");
                else if (global.params.isOSX)
                    return stringExp("macho");
                else
                    return stringExp("elf");
            case floatAbi.stringof:
                return stringExp("hard");
            case cppRuntimeLibrary.stringof:
                if (global.params.isWindows)
                {
                    if (global.params.mscoff)
                        return stringExp(global.params.mscrtlib);
                    return stringExp("snn");
                }
                return stringExp("");
            case cppStd.stringof:
                return new IntegerExp(cast(uint)global.params.cplusplus);

            default:
                return null;
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    /* All functions after this point are extern (D), as they are only relevant
     * for targets of DMD, and should not be used in front-end code.
     */

    /******************
     * Returns:
     *  true if xmm usage is supported
     */
    extern (D) bool isXmmSupported()
    {
        return global.params.is64bit || global.params.isOSX;
    }

    /**
     * Returns:
     *  true if generating code for POSIX
     */
    extern (D) @property bool isPOSIX() scope const nothrow @nogc
    out(result) { assert(result || global.params.isWindows); }
    do
    {
        return global.params.isLinux
            || global.params.isOSX
            || global.params.isFreeBSD
            || global.params.isOpenBSD
            || global.params.isDragonFlyBSD
            || global.params.isSolaris;
    }
}

////////////////////////////////////////////////////////////////////////////////
/**
 * Functions and variables specific to interfacing with extern(C) ABI.
 */
struct TargetC
{
    uint longsize;            /// size of a C `long` or `unsigned long` type
    uint long_doublesize;     /// size of a C `long double`
    uint criticalSectionSize; /// size of os critical section

    extern (D) void initialize(ref const Param params, ref const Target target)
    {
        if (params.isLinux || params.isFreeBSD || params.isOpenBSD || params.isDragonFlyBSD || params.isSolaris)
            longsize = 4;
        else if (params.isOSX)
            longsize = 4;
        else if (params.isWindows)
            longsize = 4;
        else
            assert(0);
        if (params.is64bit)
        {
            if (params.isLinux || params.isFreeBSD || params.isDragonFlyBSD || params.isSolaris)
                longsize = 8;
            else if (params.isOSX)
                longsize = 8;
        }
        if (params.is64bit && params.isWindows)
            long_doublesize = 8;
        else
            long_doublesize = target.realsize;

        criticalSectionSize = getCriticalSectionSize(params);
    }

    private static uint getCriticalSectionSize(ref const Param params) pure
    {
        if (params.isWindows)
        {
            // sizeof(CRITICAL_SECTION) for Windows.
            return params.isLP64 ? 40 : 24;
        }
        else if (params.isLinux)
        {
            // sizeof(pthread_mutex_t) for Linux.
            if (params.is64bit)
                return params.isLP64 ? 40 : 32;
            else
                return params.isLP64 ? 40 : 24;
        }
        else if (params.isFreeBSD)
        {
            // sizeof(pthread_mutex_t) for FreeBSD.
            return params.isLP64 ? 8 : 4;
        }
        else if (params.isOpenBSD)
        {
            // sizeof(pthread_mutex_t) for OpenBSD.
            return params.isLP64 ? 8 : 4;
        }
        else if (params.isDragonFlyBSD)
        {
            // sizeof(pthread_mutex_t) for DragonFlyBSD.
            return params.isLP64 ? 8 : 4;
        }
        else if (params.isOSX)
        {
            // sizeof(pthread_mutex_t) for OSX.
            return params.isLP64 ? 64 : 44;
        }
        else if (params.isSolaris)
        {
            // sizeof(pthread_mutex_t) for Solaris.
            return 24;
        }
        assert(0);
    }
}

////////////////////////////////////////////////////////////////////////////////
/**
 * Functions and variables specific to interface with extern(C++) ABI.
 */
struct TargetCPP
{
    bool reverseOverloads;    /// set if overloaded functions are grouped and in reverse order (such as in dmc and cl)
    bool exceptions;          /// set if catching C++ exceptions is supported
    bool twoDtorInVtable;     /// target C++ ABI puts deleting and non-deleting destructor into vtable

    extern (D) void initialize(ref const Param params, ref const Target target)
    {
        if (params.isLinux || params.isFreeBSD || params.isOpenBSD || params.isDragonFlyBSD || params.isSolaris)
            twoDtorInVtable = true;
        else if (params.isOSX)
            twoDtorInVtable = true;
        else if (params.isWindows)
            reverseOverloads = true;
        else
            assert(0);
        exceptions = params.isLinux || params.isFreeBSD ||
            params.isDragonFlyBSD || params.isOSX;
    }

    /**
     * Mangle the given symbol for C++ ABI.
     * Params:
     *      s = declaration with C++ linkage
     * Returns:
     *      string mangling of symbol
     */
    extern (C++) const(char)* toMangle(Dsymbol s)
    {
        static if (TARGET.Linux || TARGET.OSX || TARGET.FreeBSD || TARGET.OpenBSD || TARGET.DragonFlyBSD || TARGET.Solaris)
            return toCppMangleItanium(s);
        else static if (TARGET.Windows)
            return toCppMangleMSVC(s);
        else
            static assert(0, "fix this");
    }

    /**
     * Get RTTI mangling of the given class declaration for C++ ABI.
     * Params:
     *      cd = class with C++ linkage
     * Returns:
     *      string mangling of C++ typeinfo
     */
    extern (C++) const(char)* typeInfoMangle(ClassDeclaration cd)
    {
        static if (TARGET.Linux || TARGET.OSX || TARGET.FreeBSD || TARGET.OpenBSD || TARGET.Solaris || TARGET.DragonFlyBSD)
            return cppTypeInfoMangleItanium(cd);
        else static if (TARGET.Windows)
            return cppTypeInfoMangleMSVC(cd);
        else
            static assert(0, "fix this");
    }

    /**
     * Gets vendor-specific type mangling for C++ ABI.
     * Params:
     *      t = type to inspect
     * Returns:
     *      string if type is mangled specially on target
     *      null if unhandled
     */
    extern (C++) const(char)* typeMangle(Type t)
    {
        return null;
    }

    /**
     * Get the type that will really be used for passing the given argument
     * to an `extern(C++)` function.
     * Params:
     *      p = parameter to be passed.
     * Returns:
     *      `Type` to use for parameter `p`.
     */
    extern (C++) Type parameterType(Parameter p)
    {
        Type t = p.type.merge2();
        if (p.isReference())
            t = t.referenceTo();
        else if (p.storageClass & STC.lazy_)
        {
            // Mangle as delegate
            Type td = new TypeFunction(ParameterList(), t, LINK.d);
            td = new TypeDelegate(td);
            t = merge(t);
        }
        return t;
    }

    /**
     * Checks whether type is a vendor-specific fundamental type.
     * Params:
     *      t = type to inspect
     *      isFundamental = where to store result
     * Returns:
     *      true if isFundamental was set by function
     */
    extern (C++) bool fundamentalType(const Type t, ref bool isFundamental)
    {
        return false;
    }
}

////////////////////////////////////////////////////////////////////////////////
/**
 * Functions and variables specific to interface with extern(Objective-C) ABI.
 */
struct TargetObjC
{
    bool supported;     /// set if compiler can interface with Objective-C

    extern (D) void initialize(ref const Param params, ref const Target target)
    {
        if (params.isOSX && params.is64bit)
            supported = true;
    }
}

////////////////////////////////////////////////////////////////////////////////
extern (C++) __gshared Target target;
