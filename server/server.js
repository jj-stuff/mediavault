// Optimized Media Server with Caching and FFmpeg Limiting
import express from 'express';
import { promises as fs } from 'fs';
import path from 'path';
import cors from 'cors';
import ffmpeg from 'fluent-ffmpeg';
import { fileURLToPath } from 'url';
import { dirname } from 'path';
import pLimit from 'p-limit';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const app = express();
const PORT = process.env.PORT || 3000;
const limit = pLimit(3);

const MEDIA_DIR = process.argv[2] || process.env.MEDIA_DIR || '/Users/heathcliff/Documents/xmedia';
const CACHE_DIR = path.join(MEDIA_DIR, 'media_cache');
const THUMBNAILS_DIR = path.join(CACHE_DIR, 'thumbnails');
const SCAN_CACHE_PATH = path.join(CACHE_DIR, 'scan_cache.json');

let mediaCache = null;

const MEDIA_EXTENSIONS = new Set(['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.mp4', '.avi', '.mov', '.wmv', '.flv', '.webm', '.mp3', '.wav', '.ogg', '.m4a']);

app.use(cors());
app.use(express.json());
app.use('/media', express.static(MEDIA_DIR));
app.use('/thumbnails', express.static(THUMBNAILS_DIR));

const isMediaFile = (filename) => MEDIA_EXTENSIONS.has(path.extname(filename).toLowerCase());

async function ensureCacheDirectories() {
  await fs.mkdir(CACHE_DIR, { recursive: true });
  await fs.mkdir(THUMBNAILS_DIR, { recursive: true });
}

ensureCacheDirectories();

async function generateThumbnail(videoPath, outputPath) {
  return limit(
    () =>
      new Promise((resolve, reject) => {
        ffmpeg(videoPath)
          .screenshots({
            timestamps: ['10%'],
            filename: path.basename(outputPath),
            folder: path.dirname(outputPath),
            size: '320x320',
          })
          .on('end', resolve)
          .on('error', reject);
      })
  );
}

async function scanForMedia(dirPath, basePath = '', skipThumbnails = false) {
  const mediaFiles = [];

  try {
    const items = await fs.readdir(dirPath, { withFileTypes: true });

    for (const item of items) {
      if (item.name === 'media_cache') continue;
      const fullPath = path.join(dirPath, item.name);
      const relativePath = path.join(basePath, item.name);

      if (item.isDirectory()) {
        const subMedia = await scanForMedia(fullPath, relativePath, skipThumbnails);
        mediaFiles.push(...subMedia);
      } else if (item.isFile() && isMediaFile(item.name) && !item.name.startsWith('._') && !item.name.startsWith('.')) {
        const stats = await fs.stat(fullPath);
        const type = path.extname(item.name).slice(1).toLowerCase();

        const mediaItem = {
          name: item.name,
          path: relativePath,
          url: `/media/${relativePath.replace(/\\/g, '/')}`,
          size: stats.size,
          modified: stats.mtime,
          type,
        };

        if (!skipThumbnails && ['mp4', 'avi', 'mov', 'webm'].includes(type)) {
          const videoName = path.basename(fullPath);
          const thumbnailName = `${path.parse(videoName).name}_thumb.jpg`;
          const thumbnailPath = path.join(THUMBNAILS_DIR, thumbnailName);

          try {
            await fs.access(thumbnailPath);
            mediaItem.thumbnail = `/thumbnails/${thumbnailName}`;
          } catch {
            generateThumbnail(fullPath, thumbnailPath).catch((err) => console.error('Thumbnail generation error:', err));
          }
        }

        mediaFiles.push(mediaItem);
      }
    }
  } catch (err) {
    console.error(`Error scanning directory ${dirPath}:`, err);
  }

  return mediaFiles;
}

async function getCachedMedia() {
  try {
    if (mediaCache) return mediaCache;
    const cachedData = await fs.readFile(SCAN_CACHE_PATH, 'utf8');
    mediaCache = JSON.parse(cachedData);
    return mediaCache;
  } catch (err) {
    const users = await getUsers();
    mediaCache = {};
    for (const user of users) {
      const userPath = path.join(MEDIA_DIR, user);
      mediaCache[user] = await scanForMedia(userPath, user);
    }
    await fs.writeFile(SCAN_CACHE_PATH, JSON.stringify(mediaCache), 'utf8');
    return mediaCache;
  }
}

async function getUsers() {
  try {
    const items = await fs.readdir(MEDIA_DIR, { withFileTypes: true });
    return items.filter((i) => i.isDirectory() && i.name !== 'media_cache').map((i) => i.name);
  } catch (err) {
    console.error('Error reading media dir:', err);
    return [];
  }
}

app.get('/api/users', async (req, res) => {
  const users = await getUsers();
  res.json({ success: true, users });
});

app.get('/api/users/:username/media', async (req, res) => {
  const username = req.params.username;
  const cache = await getCachedMedia();
  const userMedia = cache[username];
  if (!userMedia) {
    return res.status(404).json({ success: false, error: 'User not found' });
  }
  res.json({ success: true, count: userMedia.length, media: userMedia });
});

app.get('/api/users/:username', async (req, res) => {
  const { username } = req.params;
  const userPath = path.join(MEDIA_DIR, username);
  try {
    await fs.access(userPath);
    const cache = await getCachedMedia();
    const mediaFiles = cache[username] || [];
    const images = mediaFiles.filter((m) => ['jpg', 'jpeg', 'png', 'webp'].includes(m.type));
    const avatar = images.length > 0 ? images[0].url : null;
    const stats = await fs.stat(userPath);
    res.json({
      success: true,
      user: {
        username,
        avatar,
        mediaCount: mediaFiles.length,
        joinDate: stats.birthtime,
      },
    });
  } catch (error) {
    res.status(404).json({ success: false, error: 'User not found' });
  }
});

app.get('/api/feed/random', async (req, res) => {
  try {
    const cache = await getCachedMedia();
    const limitNum = parseInt(req.query.limit) || 10;
    const mediaType = req.query.type;
    let allMedia = [];
    for (const [username, mediaList] of Object.entries(cache)) {
      for (const file of mediaList) {
        allMedia.push({ ...file, username, userUrl: `/api/users/${username}` });
      }
    }
    if (mediaType === 'video') {
      allMedia = allMedia.filter((m) => ['mp4', 'avi', 'mov', 'webm'].includes(m.type));
    } else if (mediaType === 'image') {
      allMedia = allMedia.filter((m) => ['jpg', 'jpeg', 'png', 'gif', 'webp'].includes(m.type));
    }
    const shuffled = allMedia.sort(() => Math.random() - 0.5).slice(0, limitNum);
    res.json({ success: true, count: shuffled.length, media: shuffled });
  } catch (error) {
    console.error('Feed error:', error);
    res.status(500).json({ success: false, error: 'Failed to generate feed' });
  }
});

app.get('/api/summary', async (req, res) => {
  try {
    const cache = await getCachedMedia();
    const summary = {};
    for (const [user, mediaList] of Object.entries(cache)) {
      summary[user] = {
        totalFiles: mediaList.length,
        totalSize: mediaList.reduce((sum, file) => sum + file.size, 0),
        types: mediaList.reduce((acc, file) => {
          acc[file.type] = (acc[file.type] || 0) + 1;
          return acc;
        }, {}),
      };
    }
    res.json({ success: true, summary });
  } catch (error) {
    res.status(500).json({ success: false, error: 'Failed to generate summary' });
  }
});

app.get('/api/thumbnail/:username/:filename', async (req, res) => {
  const { username, filename } = req.params;
  const videoPath = path.join(MEDIA_DIR, username, filename);
  const thumbnailName = `${path.parse(filename).name}_thumb.jpg`;
  const thumbnailPath = path.join(THUMBNAILS_DIR, thumbnailName);
  try {
    await fs.access(thumbnailPath);
    res.sendFile(thumbnailPath);
  } catch {
    try {
      await generateThumbnail(videoPath, thumbnailPath);
      res.sendFile(thumbnailPath);
    } catch (error) {
      res.status(500).json({ success: false, error: 'Failed to generate thumbnail' });
    }
  }
});
// Add this to your server.js
app.post('/api/deletion-list', express.json(), async (req, res) => {
  const deletionListPath = path.join(MEDIA_DIR, 'deletion_list.txt');
  const { paths } = req.body;

  try {
    await fs.writeFile(deletionListPath, paths.join('\n'), 'utf8');
    res.json({ success: true });
  } catch (error) {
    res.status(500).json({ success: false, error: error.message });
  }
});

app.get('/api/deletion-list', async (req, res) => {
  const deletionListPath = path.join(MEDIA_DIR, 'deletion_list.txt');

  try {
    const content = await fs.readFile(deletionListPath, 'utf8');
    const paths = content.split('\n').filter((p) => p.trim());
    res.json({ success: true, paths });
  } catch (error) {
    if (error.code === 'ENOENT') {
      res.json({ success: true, paths: [] });
    } else {
      res.status(500).json({ success: false, error: error.message });
    }
  }
});

app.get('/health', (req, res) => {
  res.json({ status: 'OK', mediaDir: MEDIA_DIR });
});

app.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});
