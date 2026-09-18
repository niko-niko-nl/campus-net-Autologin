/*
 * 用门户自己的 security.js 生成 RSA 加密结果，作为 PowerShell 实现的标准答案。
 * 用法: node verify-rsa.js <exponentHex> <modulusHex> <password>
 */
const fs = require('fs');
const path = require('path');

global.window = global;

// latin1 读取，保证原始字节不被 UTF-8 解码破坏（已确认该文件除 BOM 外全是 ASCII）
const src = fs.readFileSync(path.join(__dirname, 'security.js'), 'latin1').replace(/^\u00EF\u00BB\u00BF/, '');
eval(src);

const [exponent, modulus, password] = process.argv.slice(2);

RSAUtils.setMaxDigits(400);
const key = RSAUtils.getKeyPair(exponent, '', modulus);
const reversed = password.split('').reverse().join('');
process.stdout.write(RSAUtils.encryptedString(key, reversed));
