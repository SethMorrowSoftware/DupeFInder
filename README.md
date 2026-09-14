# DupeFinder 🔍

**Advanced Duplicate File Manager for Linux**

A production-ready, feature-rich duplicate file finder with comprehensive safety checks, intelligent deletion strategies, and robust error handling. Perfect for system administrators and power users who need reliable duplicate file management.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)
[![Linux](https://img.shields.io/badge/Platform-Linux-blue.svg)](https://www.linux.org/)
[![GitHub](https://img.shields.io/badge/GitHub-morroware%2FDupeFinder-blue.svg)](https://github.com/morroware/DupeFinder)

## ✨ Features

### 🛡️ **Safety First**
- **System Protection**: Automatically excludes critical system directories (`/bin`, `/lib`, `/usr`, etc.)
- **Process Awareness**: Detects files in use and prevents deletion of active libraries
- **Dry Run Mode**: Test operations safely without making changes
- **Interactive Mode**: Review and confirm each deletion with file preview
- **Smart Backups**: Optional backup creation before deletion

### 🚀 **Performance**
- **Size pre-filter**: Only files that share a size with another file are
  hashed - files of a unique size cannot be duplicates
- **Multi-threaded**: Parallel hash calculation for faster processing
- **Smart Caching**: SQLite-based cache for faster re-scans
- **Memory Monitoring**: Automatic thread adjustment based on available memory
- **Fast Mode**: Quick scanning using size + filename hashes

### 🎯 **Intelligent Deletion**
- **Keep Strategies**: Keep newest, oldest, or files in preferred locations
- **Smart Location Priority**: Automatically prefer files in better locations
- **Hardlink Mode**: Replace duplicates with hardlinks to save space
- **Quarantine**: Move duplicates to quarantine instead of deleting

### 📊 **Comprehensive Reporting**
- **HTML Reports**: Beautiful, interactive web reports
- **CSV Export**: Spreadsheet-compatible data export
- **JSON Output**: Machine-readable structured data
- **Email Reports**: Automatic email delivery of results

### 🔧 **Advanced Options**
- **Multiple Hash Algorithms**: MD5, SHA256, SHA512
- **Fuzzy Matching**: Find similar files using ssdeep
- **Symlink Support**: Follow or ignore symbolic links
- **Pattern Matching**: Include/exclude files by glob patterns
- **Resume Support**: Continue interrupted scans

## 📥 Installation

### Quick Install
```bash
# Download the script
curl -O https://raw.githubusercontent.com/morroware/DupeFinder/main/dupefinder.sh
chmod +x dupefinder.sh

# Everything required is part of a standard install (bash, GNU coreutils,
# GNU findutils). Nothing extra is needed for a basic scan.
```

### Clone Repository
```bash
# Clone the full repository
git clone https://github.com/morroware/DupeFinder.git
cd DupeFinder
chmod +x dupefinder.sh
```

### Full Feature Installation
```bash
# Optional extras, each tied to one flag
sudo apt install sqlite3 lsof trash-cli ssdeep mailutils
```

### Dependencies
| Component | Package | Required | Purpose |
|-----------|---------|----------|---------|
| Bash 4+ | `bash` | ✅ Yes | The script itself |
| GNU coreutils | `coreutils` | ✅ Yes | `sort`/`uniq`/`cut -z`, hashing |
| GNU findutils | `findutils` | ✅ Yes | `find -printf` |
| SQLite | `sqlite3` | ❌ Optional | `--cache` |
| Process monitor | `lsof` | ❌ Optional | `--enable-lsof` open-file checks |
| Trash support | `trash-cli` | ❌ Optional | `--trash` |
| Fuzzy matching | `ssdeep` | ❌ Optional | `--fuzzy` |
| Email reports | `mailutils` | ❌ Optional | `--email` |

The zero-terminated `sort`/`uniq`/`cut` options need coreutils 8.25 or newer
(Debian 9+, Ubuntu 16.04+). The script checks for them at startup and says so
if they are missing.

## 🚀 Quick Start

### Basic Usage
```bash
# Safe scan of Downloads folder
./dupefinder.sh --path ~/Downloads --dry-run --verbose

# Interactive cleanup with system protection
./dupefinder.sh --path ~/Documents --skip-system --interactive

# Fast scan of Pictures folder
./dupefinder.sh --path ~/Pictures --fast --min-size 1M
```

### System-Wide Scan (Advanced)
```bash
# Safe system-wide duplicate detection
./dupefinder.sh --path / --skip-system --dry-run --min-size 10M
```

## 📚 Usage Examples

### 👤 **Beginner - Home User Scenarios**

#### 🧹 **Clean Up Downloads Folder**
```bash
# Safe cleanup of Downloads with preview
./dupefinder.sh --path ~/Downloads --interactive --trash --verbose
```

#### 📱 **Organize Phone Photos**
```bash
# Find duplicate photos from phone sync, keep newest
./dupefinder.sh \
  --path ~/Pictures \
  --pattern "*.jpg" --pattern "*.jpeg" --pattern "*.png" \
  --keep-newest \
  --interactive \
  --verbose
```

#### 🎵 **Music Library Cleanup**
```bash
# Find duplicate music files, move to quarantine for review
./dupefinder.sh \
  --path ~/Music \
  --pattern "*.mp3" --pattern "*.flac" --pattern "*.m4a" \
  --min-size 1M \
  --quarantine ~/duplicate_music_review \
  --verbose
```

#### 📄 **Document Organization**
```bash
# Find duplicate documents, backup before deletion
./dupefinder.sh \
  --path ~/Documents \
  --pattern "*.pdf" --pattern "*.doc*" --pattern "*.txt" \
  --backup ~/document_backups \
  --interactive \
  --csv document_duplicates.csv
```

### 🔧 **Intermediate - Power User Scenarios**

#### 💿 **Media Collection Management**
```bash
# Comprehensive media cleanup with hardlinks to save space
./dupefinder.sh \
  --path ~/Media \
  --pattern "*.mkv" --pattern "*.mp4" --pattern "*.avi" \
  --min-size 50M \
  --hardlink \
  --keep-newest \
  --csv media_report.csv \
  --verbose
```

#### 🖼️ **Photography Workflow**
```bash
# Professional photo management with similarity detection
./dupefinder.sh \
  --path ~/Photography \
  --pattern "*.raw" --pattern "*.cr2" --pattern "*.nef" \
  --fuzzy \
  --threshold 85 \
  --keep-path ~/Photography/edited \
  --backup ~/photo_backups \
  --json photo_analysis.json
```

#### 🎮 **Game Files Cleanup**
```bash
# Find duplicate game files and installers
./dupefinder.sh \
  --path ~/Games \
  --pattern "*.zip" --pattern "*.exe" --pattern "*.msi" \
  --min-size 10M \
  --smart-delete \
  --quarantine ~/game_duplicates \
  --log ~/game_cleanup.log
```

#### 💾 **Backup Verification**
```bash
# Verify backup integrity and find redundant backups
./dupefinder.sh \
  --path ~/Backups \
  --sha256 \
  --verify \
  --csv backup_analysis.csv \
  --json backup_report.json \
  --threads 4
```

#### 📚 **Digital Library Management**
```bash
# Organize ebooks and documents with fuzzy matching
./dupefinder.sh \
  --path ~/Library \
  --pattern "*.pdf" --pattern "*.epub" --pattern "*.mobi" \
  --fuzzy \
  --threshold 92 \
  --keep-newest \
  --csv library_duplicates.csv \
  --verbose
```

### 🏢 **Advanced - System Administrator Scenarios**

#### 🖥️ **Workstation Maintenance**
```bash
# Safe system-wide scan excluding critical areas
./dupefinder.sh \
  --path / \
  --skip-system \
  --min-size 10M \
  --exclude /proc --exclude /sys --exclude /dev \
  --dry-run \
  --threads 6 \
  --csv workstation_analysis.csv \
  --log /var/log/dupefinder.log
```

#### 📁 **Shared Network Storage**
```bash
# Enterprise file server cleanup with comprehensive reporting
./dupefinder.sh \
  --path /mnt/fileserver \
  --min-size 1M \
  --threads 8 \
  --cache \
  --sha256 \
  --smart-delete \
  --backup /backup/before_cleanup \
  --csv /reports/fileserver_duplicates.csv \
  --json /reports/fileserver_analysis.json \
  --email sysadmin@company.com \
  --log /var/log/fileserver_cleanup.log
```

#### 👥 **User Home Directory Audit**
```bash
# Scan all user directories for duplicates
for user in $(ls /home); do
  echo "Scanning /home/$user"
  ./dupefinder.sh \
    --path "/home/$user" \
    --min-size 5M \
    --dry-run \
    --csv "/reports/${user}_duplicates.csv" \
    --quiet
done
```

#### 🗄️ **Database Storage Optimization**
```bash
# Find duplicate database dumps and backups
./dupefinder.sh \
  --path /var/backups/databases \
  --pattern "*.sql" --pattern "*.dump" --pattern "*.bak" \
  --keep-newest \
  --hardlink \
  --threads 4 \
  --csv database_backup_analysis.csv \
  --log /var/log/db_cleanup.log
```

#### 📦 **Software Repository Management**
```bash
# Clean up package caches and installers
./dupefinder.sh \
  --path /opt/software \
  --pattern "*.deb" --pattern "*.rpm" --pattern "*.tar.gz" \
  --min-size 1M \
  --keep-newest \
  --quarantine /opt/duplicate_packages \
  --csv package_duplicates.csv \
  --verbose
```

#### 🔧 **Log File Management**
```bash
# Find duplicate log files across the system
./dupefinder.sh \
  --path /var/log \
  --pattern "*.log" --pattern "*.log.*" \
  --exclude /var/log/journal \
  --min-size 1M \
  --keep-newest \
  --dry-run \
  --csv log_duplicates.csv
```

#### 🌐 **Web Server Content**
```bash
# Web server asset deduplication
./dupefinder.sh \
  --path /var/www \
  --pattern "*.jpg" --pattern "*.png" --pattern "*.css" --pattern "*.js" \
  --hardlink \
  --backup /backup/web_assets \
  --threads 6 \
  --json web_asset_analysis.json \
  --log /var/log/web_cleanup.log
```

#### 🚀 **High-Performance Mass Storage**
```bash
# Large-scale storage system with resume capability
./dupefinder.sh \
  --path /storage/archive \
  --min-size 100M \
  --threads 16 \
  --cache \
  --sha512 \
  --resume \
  --csv /reports/massive_scan.csv \
  --json /reports/massive_analysis.json \
  --email storage-team@company.com \
  --log /var/log/massive_scan.log
```

#### 🔄 **Automated Scheduled Cleanup**
```bash
#!/bin/bash
# Weekly automated cleanup script for cron
./dupefinder.sh \
  --path /data/shared \
  --min-size 10M \
  --delete \
  --smart-delete \
  --yes \
  --cache \
  --csv "/reports/weekly_$(date +%Y%m%d).csv" \
  --email admin@company.com \
  --log /var/log/weekly_cleanup.log \
  --quiet

# --smart-delete only picks which copy to keep; --delete is what removes the
# others. Without a terminal to confirm on, --yes is required or the run
# reports what it found and changes nothing.

# Add to crontab: 0 2 * * 0 /path/to/weekly_cleanup.sh
```

### 🧪 **Specialized Use Cases**

#### 🔬 **Scientific Data Management**
```bash
# Research data with high precision verification
./dupefinder.sh \
  --path /research/datasets \
  --pattern "*.csv" --pattern "*.xlsx" --pattern "*.dat" \
  --sha512 \
  --verify \
  --keep-oldest \
  --backup /research/backups \
  --json research_analysis.json
```

#### 🎬 **Video Production**
```bash
# Video editing project cleanup
./dupefinder.sh \
  --path /projects/video \
  --pattern "*.mov" --pattern "*.mp4" --pattern "*.avi" \
  --min-size 100M \
  --fuzzy \
  --threshold 95 \
  --quarantine /projects/duplicate_review \
  --csv video_duplicates.csv
```

#### 🏗️ **Development Environment**
```bash
# Clean up development artifacts
./dupefinder.sh \
  --path ~/dev \
  --exclude ~/dev/.git \
  --pattern "*.tar.gz" --pattern "*.zip" --pattern "node_modules" \
  --min-size 1M \
  --smart-delete \
  --csv dev_cleanup.csv \
  --verbose
```

## ⚙️ Command Reference

### Basic Options
| Option | Description |
|--------|-------------|
| `-p, --path PATH` | Search directory (default: current) |
| `-o, --output DIR` | Output directory for reports |
| `-h, --help` | Show help message |
| `-V, --version` | Show version information |

### Search Filters
| Option | Description |
|--------|-------------|
| `-m, --min-size SIZE` | Minimum file size (e.g., 1M, 500K) |
| `-M, --max-size SIZE` | Maximum file size |
| `-t, --pattern GLOB` | File pattern (e.g., "*.mp3") |
| `-e, --exclude PATH` | Exclude directory |
| `-l, --level DEPTH` | Maximum directory depth |
| `-z, --empty` | Include empty files |
| `-a, --all` | Include hidden files |
| `-f, --follow-symlinks` | Follow symbolic links |

### Safety Options
| Option | Description |
|--------|-------------|
| `--skip-system` | Skip system directories (recommended) |
| `--force-system` | Allow system file deletion (dangerous!) |
| `-n, --dry-run` | Preview actions without execution |
| `-i, --interactive` | Confirm each deletion |
| `--verify` | Byte-by-byte verification |

### Deletion Modes
| Option | Description |
|--------|-------------|
| `-d, --delete` | Delete duplicate files |
| `--hardlink` | Replace with hardlinks |
| `--trash` | Move to trash (requires trash-cli) |
| `--quarantine DIR` | Move to quarantine directory |

### Keep Strategies
| Option | Description |
|--------|-------------|
| `-k, --keep-newest` | Keep the newest file |
| `-K, --keep-oldest` | Keep the oldest file |
| `--keep-path PATH` | Prefer files in specific path |
| `--smart-delete` | Use intelligent location priorities |

### Performance
| Option | Description |
|--------|-------------|
| `--threads N` | Number of processing threads |
| `--fast` | Fast mode (size + name hash) |
| `--cache` | Use SQLite cache for re-scans |

### Hash Algorithms
| Option | Description |
|--------|-------------|
| `-s, --sha256` | Use SHA256 hashing |
| `--sha512` | Use SHA512 hashing |
| Default | MD5 hashing (fastest) |

### Reports
| Option | Description |
|--------|-------------|
| `-c, --csv FILE` | Generate CSV report |
| `--json FILE` | Generate JSON report |
| `--email EMAIL` | Email HTML report |
| `--log FILE` | Log file location |
| `-v, --verbose` | Detailed output |
| `-q, --quiet` | Minimal output |

### Advanced
| Option | Description |
|--------|-------------|
| `--fuzzy` | Fuzzy matching (requires ssdeep) |
| `--threshold PCT` | Similarity threshold (default: 95) |
| `--backup DIR` | Backup before deletion |
| `--resume` | Resume interrupted scan |
| `--config FILE` | Load configuration file |

## 🛡️ Safety Features

### Automatic Protection
- **Critical System Files**: Never deletes essential system binaries or libraries
- **Files in Use**: Detects and skips files currently being used by processes
- **Permission Checks**: Respects file ownership and permissions
- **Cross-Filesystem**: Prevents hardlinks across different filesystems

### Built-in Safeguards
- **Root Protection**: Non-root users cannot delete root-owned files
- **Shared Library Detection**: Checks if libraries are loaded in memory
- **Interactive Confirmation**: Manual approval for critical operations
- **Backup Creation**: Optional file backup before deletion

## 📊 Report Examples

### HTML Report Features
- 📈 **Visual Statistics**: Files scanned, duplicates found, space wasted
- 🗂️ **Expandable Groups**: Click to view all files in each duplicate group
- ⚠️ **Safety Indicators**: System files clearly marked
- 📱 **Responsive Design**: Works on desktop and mobile
- 🎨 **Modern UI**: Clean, professional appearance

### CSV Report Columns
- Hash, File Path, Size (bytes), Size (human), Group ID, System File

### JSON Structure
```json
{
  "metadata": {
    "version": "1.2.4",
    "generated": "2024-01-15T10:30:00Z",
    "total_files": 15420,
    "total_duplicates": 1205,
    "space_wasted": 2847362048
  },
  "groups": [...]
}
```

## ⚠️ Important Safety Notes

1. **Always use `--dry-run` first** to preview actions
2. **Enable `--skip-system`** for system-wide scans
3. **Test with small directories** before large scans
4. **Use `--backup`** for important files
5. **Never run as root** unless absolutely necessary

## 🐛 Troubleshooting

### Common Issues

**"GNU awk required" error:**
```bash
sudo apt install gawk
```

**Permission denied errors:**
```bash
# Check file ownership and permissions
ls -la problematic_file
```

**Out of memory during large scans:**
```bash
# Reduce thread count
./dupefinder.sh --path /large/directory --threads 2
```

**Hash calculation timeout:**
```bash
# Use fast mode for large files
./dupefinder.sh --path /directory --fast
```

### Getting Help
- Check log files for detailed error information
- Use `--verbose` mode for debugging
- Reduce scope with `--max-depth` or file patterns
- Test with `--dry-run` to identify issues safely

## 🔧 Configuration File

Create `~/.dupefinder.conf` for default settings:

```bash
# Default configuration
SEARCH_PATH="/home/user/Documents"
OUTPUT_DIR="/home/user/duplicate_reports"
SKIP_SYSTEM_FOLDERS=1
VERBOSE=1
MIN_SIZE=1048576
THREADS=4
USE_CACHE=1
```

## 🚀 Performance Tips

1. **Use SSD storage** for better I/O performance
2. **Enable caching** (`--cache`) for repeated scans
3. **Adjust thread count** based on CPU cores and available memory
4. **Use fast mode** (`--fast`) for initial scans
5. **Filter by size** (`--min-size`) to skip small files
6. **Exclude unnecessary directories** (`--exclude`)

## 🤝 Contributing

Contributions are welcome! Please feel free to submit pull requests or create issues for bugs and feature requests.

### Development Setup
```bash
git clone https://github.com/morroware/DupeFinder.git
cd DupeFinder
chmod +x dupefinder.sh
```

### Testing
```bash
# Create test directory with duplicates
mkdir -p test/dir1 test/dir2
echo "duplicate content" > test/dir1/file1.txt
echo "duplicate content" > test/dir2/file1.txt

# Test the script
./dupefinder.sh --path test --dry-run --verbose
```

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

*DupeFinder v1.2.4 - Advanced Duplicate File Manager*
