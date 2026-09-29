// index.js
const {
  default: makeWASocket,
  useMultiFileAuthState,
  downloadMediaMessage,
  DisconnectReason,
} = require('@whiskeysockets/baileys');
const { Boom } = require('@hapi/boom');
const P = require('pino');
const qrcode = require('qrcode-terminal');
const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');
const sharp = require('sharp');

const TMP = './tmp';
if (!fs.existsSync(TMP)) fs.mkdirSync(TMP, { recursive: true });

async function start() {
  const { state, saveCreds } = await useMultiFileAuthState('./auth');

  const sock = makeWASocket({
    auth: state,
    logger: P({ level: 'silent' }),
    printQRInTerminal: false,
  });

  sock.ev.on('creds.update', saveCreds);

  sock.ev.on('connection.update', ({ connection, lastDisconnect, qr }) => {
    if (qr) qrcode.generate(qr, { small: true });
    if (connection === 'close') {
      const code = new Boom(lastDisconnect?.error)?.output?.statusCode;
      if (code !== DisconnectReason.loggedOut) start();
      else console.log('Sessão encerrada. Apague a pasta ./auth e reconecte.');
    } else if (connection === 'open') {
      console.log('✅ Bot conectado');
    }
  });

  sock.ev.on('messages.upsert', async ({ messages, type }) => {
    if (type !== 'notify') return;
    const msg = messages[0];
    if (!msg.message) return;

    // Ignora mensagens enviadas por você mesmo (opcional)
    // if (msg.key.fromMe) return;

    const text =
      msg.message.conversation ||
      msg.message.extendedTextMessage?.text ||
      msg.message.imageMessage?.caption ||
      msg.message.videoMessage?.caption ||
      '';

    if (!text.trim().toLowerCase().startsWith('.fig')) return;

    // Detecta imagem ou vídeo (com ou sem quoted)
    const imgMsg =
      msg.message.imageMessage ||
      msg.message.extendedTextMessage?.contextInfo?.quotedMessage?.imageMessage;

    const vidMsg =
      msg.message.videoMessage ||
      msg.message.extendedTextMessage?.contextInfo?.quotedMessage?.videoMessage;

    if (!imgMsg && !vidMsg) {
      await sock.sendMessage(msg.key.remoteJid, {
        text: '⚠️ Responda a uma imagem ou vídeo com .fig',
      }, { quoted: msg });
      return;
    }

    try {
      await sock.sendMessage(msg.key.remoteJid, { text: '⏳ Gerando figurinha...' }, { quoted: msg });

      // Para quoted, precisamos montar a mensagem com o conteúdo citado
      const mediaMsg = imgMsg
        ? { message: { imageMessage: imgMsg }, key: msg.key }
        : { message: { videoMessage: vidMsg }, key: msg.key };

      const buffer = await downloadMediaMessage(
        mediaMsg,
        'buffer',
        {},
        { logger: P({ level: 'silent' }), reuploadRequest: sock.updateMediaMessage }
      );

      const id = Date.now();
      const inputPath = path.join(TMP, `in_${id}`);
      const outputPath = path.join(TMP, `out_${id}.webp`);

      if (imgMsg) {
        fs.writeFileSync(inputPath, buffer);
        await sharp(inputPath)
          .resize(512, 512, { fit: 'inside', withoutEnlargement: true })
          .webp({ quality: 80 })
          .toFile(outputPath);
      } else {
        // vídeo → webp animado
        fs.writeFileSync(inputPath, buffer);
        await new Promise((resolve, reject) => {
          exec(
            `ffmpeg -y -i "${inputPath}" -vcodec libwebp -filter:v "fps=15,scale=512:512:force_original_aspect_ratio=decrease" ` +
            `-lossless 0 -compression_level 6 -q:v 50 -loop 0 -preset picture -an -vsync 0 "${outputPath}"`,
            (err) => (err ? reject(err) : resolve())
          );
        });
      }

      await sock.sendMessage(
        msg.key.remoteJid,
        { sticker: fs.readFileSync(outputPath) },
        { quoted: msg }
      );

      fs.unlinkSync(inputPath);
      fs.unlinkSync(outputPath);
    } catch (err) {
      console.error(err);
      await sock.sendMessage(msg.key.remoteJid, {
        text: '❌ Erro ao gerar figurinha.',
      }, { quoted: msg });
    }
  });
}

start();
