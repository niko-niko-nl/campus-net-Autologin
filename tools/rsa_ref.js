#!/usr/bin/env node
/*
 * =============================================================================
 *  rsa_ref.js —— 深澜门户 security.js 里那套 ohdave RSA 的等价参考实现
 * =============================================================================
 *
 *  为什么要自己写一份：
 *    门户的 security.js 是第三方文件，本仓库不分发。原来的 tools\test-rsa.ps1
 *    必须先联网从门户下载它才能跑，等于开箱即废。
 *    这里用「裸 modpow」重写一遍算法（原版用 Barrett 约减，结果等价），
 *    于是对拍变成完全离线、可重复的。
 *
 *  与原版的差异（只为实现方式，不影响输出）：
 *    - 用 BigInt 的朴素快速幂替代 BarrettMu，数学等价
 *    - 用 toString(16) + 左补齐 4 位替代 biToHex
 *
 *  必须保持一致的行为（踩过的坑，别改）：
 *    1. 补零是【追加在原文之后】：JS 原版里索引 i 从 s.length 续着走。
 *       若写成从 0 开始，补的零会覆盖原文，结果全错。
 *    2. chunkSize = 2 * biHighIndex(n)，也就是 modulus 的 16bit 位数减一。
 *       1024 位密钥 → 64 位 → chunkSize = 126（不是 128）。
 *    3. 明文按小端解释为 16bit 位组：digit[j] = a[2j] + (a[2j+1] << 8)
 *    4. 输出每位固定补足 4 个十六进制字符；多块之间用空格连接
 *    5. 空串输入返回空串（不是 "0000"）—— 原版的补零循环条件
 *       `a.length % chunkSize != 0` 在 a 为空时直接为假，一个块都不产生
 *
 *  ⚠️ 已知边界：只支持码元 <= 255 的字符（ASCII / Latin-1）
 *     ohdave 原版把数据放进「16bit 数字槽」，乘法时对每一位做 & 0xFFFF 截断。
 *     charCodeAt 对中文返回 20013 这类大于 255 的值，进入乘法后被截断，
 *     于是原版对非 ASCII 产生的是实现相关的值 —— 实测「Portal 原版 / 本文件 /
 *     PowerShell 实现」三方对小写 ASCII 完全一致，对中文则两两都不同。
 *     与其输出一个看起来对、实际复刻不了的密文，这里直接抛错。
 *     （对本校无影响：秘密码是 6 位数字；且门户 passwordEncrypt=false，不走 RSA）
 *
 *  用法：
 *    node rsa_ref.js <exponentHex> <modulusHex> <password>
 *      —— 打印 RSA(反转(password))，也就是门户提交时 password 字段的值
 * =============================================================================
 */
'use strict';

/*
 * 门户的 security.js 会往全局挂一个同名的 BigInt 构造函数（ohdave 的 BigInt 类）：
 *     var BigInt = $w.BigInt = function (flag) { ... }
 * 如果在同一个进程里 eval 过它，全局 BigInt 就被顶掉了，下面所有 BigInt(...) 调用
 * 都会变成调用那个类 —— 报 "Cannot mix BigInt and other types"。
 * 所以在模块加载时先把原生实现抓住，不依赖全局。
 * （写对拍脚本时若把 security.js 和本文件放同一个进程，就会踩到这个。）
 */
const NativeBigInt = BigInt;

/** 16 进制字符串 → BigInt（前置 0 保证正数语义） */
function bigFromHex(hex) {
    const h = String(hex).trim().replace(/^0x/i, '');
    return NativeBigInt('0x' + (h.length ? h : '0'));
}

/** 模幂：替代原版的 BarrettMu，数学等价 */
function modPow(base, exp, mod) {
    let result = 1n;
    let b = base % mod;
    let e = exp;
    while (e > 0n) {
        if (e & 1n) result = (result * b) % mod;
        b = (b * b) % mod;
        e >>= 1n;
    }
    return result;
}

/** 等价于 RSAUtils.biHighIndex：最高非零 16bit 位的下标（最低位为 0） */
function biHighIndex(hex) {
    const h = String(hex).trim().toLowerCase().replace(/^0+/, '');
    if (!h) return 0;
    return Math.ceil(h.length / 4) - 1;
}

/** 等价于 RSAKeyPair 的 chunkSize = 2 * biHighIndex(modulus) */
function chunkSizeOf(modulusHex) {
    return 2 * biHighIndex(modulusHex);
}

/**
 * 等价于 RSAUtils.encryptedString(key, s)
 * @param {string} exponentHex  公钥指数，一般是 "10001"
 * @param {string} modulusHex   公钥模数
 * @param {string} s            已经处理好的明文（门户侧是先反转再传进来）
 * @returns {string} 十六进制密文，多块以空格分隔
 */
function encryptedString(exponentHex, modulusHex, s) {
    const e = bigFromHex(exponentHex);
    const m = bigFromHex(modulusHex);
    const chunkSize = chunkSizeOf(modulusHex);
    if (chunkSize < 1) throw new Error('modulus too short for chunking');

    // 1. 明文转码元数组
    const a = [];
    let i = 0;
    while (i < s.length) {
        const code = s.charCodeAt(i);
        if (code > 0xFF) {
            throw new Error(
                'rsa_ref.js 只支持码元 <= 255 的输入：ohdave 原版对非 ASCII 的行为是' +
                '未定义的（16bit 数字槽会被 & 0xFFFF 截断），复刻它没有意义。' +
                '出错字符：' + JSON.stringify(s[i]) + ' (charCode ' + code + ')'
            );
        }
        a[i] = code;
        i++;
    }

    // 2. 补零——注意 i 是续着走的，零追加在原文之后
    while (a.length % chunkSize !== 0) { a[i++] = 0; }

    // 3. 逐块加密
    const al = a.length;
    let result = '';
    for (i = 0; i < al; i += chunkSize) {
        // 小端 16bit 位组
        let block = 0n;
        for (let j = 0; j < chunkSize / 2; j++) {
            const lo = a[i + 2 * j] || 0;
            const hi = a[i + 2 * j + 1] || 0;
            block += NativeBigInt(lo + hi * 256) << NativeBigInt(16 * j);
        }
        const crypt = modPow(block, e, m);
        // 等价于 digitToHex：每位固定 4 个十六进制字符
        let text = crypt.toString(16);
        while (text.length % 4 !== 0) text = '0' + text;
        result += text + ' ';
    }

    // 去掉最后那个空格（空串时 result 为空，这里返回空串）
    return result.substring(0, result.length - 1);
}

/**
 * 门户提交时 password 字段的值：RSA(反转(密码))
 */
function encryptPassword(exponentHex, modulusHex, password) {
    return encryptedString(exponentHex, modulusHex, password.split('').reverse().join(''));
}

module.exports = { encryptedString, encryptPassword, chunkSizeOf, biHighIndex };

if (require.main === module) {
    const [exponentHex, modulusHex, password] = process.argv.slice(2);
    if (!exponentHex || !modulusHex || password === undefined) {
        process.stderr.write('usage: node rsa_ref.js <exponentHex> <modulusHex> <password>\n');
        process.exit(2);
    }
    process.stdout.write(encryptPassword(exponentHex, modulusHex, password));
}
