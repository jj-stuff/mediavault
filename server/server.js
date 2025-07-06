import express from 'express';
import { promises as fs } from 'fs';
import path from 'path';
import cors from 'cors';

const app = express();
const PORT = process.env.PORT || 3000;

// Configure your media directory path here
const MEDIA_DIR = process.env.MEDIA_DIR || './media';

// Supported media file extensions
const MEDIA_EXTENSIONS = new Set(['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.mp4', '.avi', '.mov', '.wmv', '.flv', '.webm', '.mp3', '.wav', '.ogg', '.m4a']);

// Middleware
app.use(cors());
app.use(express.json());

// Serve static files from media directory
app.use('/media', express.static(MEDIA_DIR));

// Helper function to check if file is media
const isMediaFile = (filename) => {
  const ext = path.extname(filename).toLowerCase();
  return MEDIA_EXTENSIONS.has(ext);
};

// Recursively scan directory for media files
async function scanForMedia(dirPath, basePath = '') {
  const mediaFiles = [];

  try {
    const items = await fs.readdir(dirPath, { withFileTypes: true });

    for (const item of items) {
      const fullPath = path.join(dirPath, item.name);
      const relativePath = path.join(basePath, item.name);

      if (item.isDirectory()) {
        // Recursively scan subdirectories
        const subMedia = await scanForMedia(fullPath, relativePath);
        mediaFiles.push(...subMedia);
      } else if (item.isFile() && isMediaFile(item.name)) {
        // Add media file info
        const stats = await fs.stat(fullPath);
        mediaFiles.push({
          name: item.name,
          path: relativePath,
          url: `/media/${relativePath.replace(/\\/g, '/')}`,
          size: stats.size,
          modified: stats.mtime,
          type: path.extname(item.name).slice(1).toLowerCase(),
        });
      }
    }
  } catch (error) {
    console.error(`Error scanning directory ${dirPath}:`, error);
  }

  return mediaFiles;
}

// Get all users (top-level directories)
async function getUsers() {
  try {
    const items = await fs.readdir(MEDIA_DIR, { withFileTypes: true });
    return items.filter((item) => item.isDirectory()).map((item) => item.name);
  } catch (error) {
    console.error('Error getting users:', error);
    return [];
  }
}

// Routes

// Get all users
app.get('/api/users', async (req, res) => {
  try {
    const users = await getUsers();
    res.json({
      success: true,
      count: users.length,
      users,
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      error: 'Failed to retrieve users',
    });
  }
});

// Get user profile with avatar
app.get('/api/users/:username', async (req, res) => {
  const { username } = req.params;
  const userPath = path.join(MEDIA_DIR, username);

  try {
    await fs.access(userPath);

    // Get first image as avatar (you can customize this logic)
    const mediaFiles = await scanForMedia(userPath, username);
    const images = mediaFiles.filter((m) => ['jpg', 'jpeg', 'png', 'webp'].includes(m.type));
    const avatar = images.length > 0 ? images[0].url : null;

    res.json({
      success: true,
      user: {
        username,
        avatar,
        mediaCount: mediaFiles.length,
        joinDate: (await fs.stat(userPath)).birthtime,
      },
    });
  } catch (error) {
    res.status(404).json({
      success: false,
      error: 'User not found',
    });
  }
});

// Get all media for a specific user
app.get('/api/users/:username/media', async (req, res) => {
  const { username } = req.params;
  const userPath = path.join(MEDIA_DIR, username);

  try {
    // Check if user directory exists
    await fs.access(userPath);

    // Scan for all media files in user's directory
    const mediaFiles = await scanForMedia(userPath, username);

    // Group by file type if requested
    const groupByType = req.query.groupByType === 'true';

    if (groupByType) {
      const grouped = mediaFiles.reduce((acc, file) => {
        if (!acc[file.type]) acc[file.type] = [];
        acc[file.type].push(file);
        return acc;
      }, {});

      res.json({
        success: true,
        user: username,
        count: mediaFiles.length,
        media: grouped,
      });
    } else {
      res.json({
        success: true,
        user: username,
        count: mediaFiles.length,
        media: mediaFiles,
      });
    }
  } catch (error) {
    if (error.code === 'ENOENT') {
      res.status(404).json({
        success: false,
        error: 'User not found',
      });
    } else {
      res.status(500).json({
        success: false,
        error: 'Failed to retrieve media files',
      });
    }
  }
});

// Get random media from all users (for feed)
app.get('/api/feed/random', async (req, res) => {
  try {
    const limit = parseInt(req.query.limit) || 10;
    const mediaType = req.query.type; // 'video', 'image', or undefined for all

    // Get all users
    const users = await getUsers();
    let allMedia = [];

    // Collect all media from all users
    for (const user of users) {
      const userPath = path.join(MEDIA_DIR, user);
      const mediaFiles = await scanForMedia(userPath, user);

      // Add username to each media item
      mediaFiles.forEach((file) => {
        file.username = user;
        file.userUrl = `/api/users/${user}`;
      });

      allMedia.push(...mediaFiles);
    }

    // Filter by type if requested
    if (mediaType === 'video') {
      allMedia = allMedia.filter((m) => ['mp4', 'avi', 'mov', 'webm'].includes(m.type));
    } else if (mediaType === 'image') {
      allMedia = allMedia.filter((m) => ['jpg', 'jpeg', 'png', 'gif', 'webp'].includes(m.type));
    }

    // Shuffle and limit
    const shuffled = allMedia.sort(() => Math.random() - 0.5).slice(0, limit);

    res.json({
      success: true,
      count: shuffled.length,
      media: shuffled,
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      error: 'Failed to generate feed',
    });
  }
});

// Get summary for all users
app.get('/api/summary', async (req, res) => {
  try {
    const users = await getUsers();
    const summary = {};

    for (const user of users) {
      const userPath = path.join(MEDIA_DIR, user);
      const mediaFiles = await scanForMedia(userPath, user);

      summary[user] = {
        totalFiles: mediaFiles.length,
        totalSize: mediaFiles.reduce((sum, file) => sum + file.size, 0),
        types: mediaFiles.reduce((acc, file) => {
          acc[file.type] = (acc[file.type] || 0) + 1;
          return acc;
        }, {}),
      };
    }

    res.json({
      success: true,
      summary,
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      error: 'Failed to generate summary',
    });
  }
});

// Health check
app.get('/health', (req, res) => {
  res.json({ status: 'OK', mediaDir: MEDIA_DIR });
});

// Start server
app.listen(PORT, () => {
  console.log(`Media server running on port ${PORT}`);
  console.log(`Serving media from: ${path.resolve(MEDIA_DIR)}`);
});

// Error handling
process.on('unhandledRejection', (error) => {
  console.error('Unhandled rejection:', error);
});

process.on('uncaughtException', (error) => {
  console.error('Uncaught exception:', error);
  process.exit(1);
});
