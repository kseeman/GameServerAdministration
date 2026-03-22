# Backup/Restore Integration for Instance + Preset Architecture

## Overview
The new backup/restore system integrates seamlessly with the **instance + preset** architecture while maintaining the Docker volume-based approach from your existing system.

## Key Features

### 1. **Environment + Instance Organization**
```
backups/
├── production/
│   ├── main/
│   │   ├── tournament_main_production_20240322_153000.tar.gz
│   │   ├── tournament_main_production_20240322_153000.meta.json
│   │   └── hardcore_main_production_20240321_120000.tar.gz
│   └── backup/
│       └── casual_backup_production_20240322_100000.tar.gz
└── staging/
    └── test/
        └── testing_test_staging_20240322_140000.tar.gz
```

### 2. **Enhanced Metadata**
Each backup includes comprehensive metadata:
```json
{
  "game": "palworld",
  "instance": "main", 
  "environment": "production",
  "world_id": "ABC123...",
  "active_preset": "tournament",
  "backup_name": "tournament_main_production_20240322_153000",
  "timestamp": "2024-03-22T15:30:00Z",
  "infrastructure": {
    "ports": {"game": 8215, "query": 27019, "rcon": 25577},
    "server_name": "Vauldamir's Server - Tournament",
    "max_players": 32
  },
  "preset_location": "games/palworld/presets/tournament.json",
  "volume_name": "palworld-vol-production-main",
  "container_name": "palworld-production-main",
  "backup_method": "docker_volume"
}
```

## Command Examples

### **Basic Operations**
```bash
# Create backup with current preset name
./server-manager.sh backup --game palworld --instance main --env production

# Restore from backup 
./server-manager.sh restore --game palworld --instance main --env production --backup tournament_main_20240322.tar.gz

# List backups for instance
./server-manager.sh list-backups --game palworld --instance main --env production
```

### **Live Configuration Switching with Backup**
```bash
# Backup current state before tournament
./server-manager.sh backup --game palworld --instance main --env production

# Switch to tournament mode (same server, different preset)  
./server-manager.sh restart --game palworld --instance main --env production --preset tournament

# After event, restore previous state
./server-manager.sh restore --game palworld --instance main --env production --backup casual_main_20240322.tar.gz
```

### **Multi-Instance Management**
```bash
# Production main server (tournament)
./server-manager.sh start --game palworld --instance main --env production --preset tournament
./server-manager.sh backup --game palworld --instance main --env production

# Production backup server (casual)
./server-manager.sh start --game palworld --instance backup --env production --preset casual  
./server-manager.sh backup --game palworld --instance backup --env production

# Staging test server
./server-manager.sh start --game palworld --instance test --env staging --preset hardcore
./server-manager.sh backup --game palworld --instance test --env staging
```

## Technical Implementation

### **Backup Naming Convention**
`{active_preset}_{instance}_{environment}_{timestamp}.tar.gz`

Examples:
- `tournament_main_production_20240322_153000.tar.gz`
- `hardcore_test_staging_20240321_140000.tar.gz`
- `casual_backup_production_20240320_100000.tar.gz`

### **Volume Naming** 
`{game}-vol-{environment}-{instance}`

Examples:
- `palworld-vol-production-main`
- `palworld-vol-staging-test`

### **Container Naming**
`{game}-{environment}-{instance}`

Examples: 
- `palworld-production-main`
- `palworld-staging-test`

## Integration Points

### **With Server Operations**
- **Emergency Backup**: Automatic backup before destructive operations
- **Preset Tracking**: Active preset stored in backup metadata
- **Health Validation**: Backup validation includes preset consistency

### **With Environment Separation**
- **Isolated Backups**: Production/staging backups completely separated
- **Infrastructure Context**: Backup includes environment-specific settings
- **Port Assignments**: Environment-specific port mappings preserved

### **With Game Plugins**
- **Game-Specific Logic**: Palworld plugin handles world ID extraction
- **Volume Operations**: Docker volume backup/restore using temporary containers
- **Configuration Preservation**: GameUserSettings.ini properly managed

## Benefits Over Previous System

1. **Clear Organization**: Environment + instance structure prevents confusion
2. **Preset Integration**: Active gameplay mode preserved with world data
3. **Infrastructure Separation**: Port/password/server name handled separately from game data  
4. **Multi-Instance Support**: Multiple servers per environment with separate backups
5. **Live Switching**: Change game modes without losing world data
6. **Environment Safety**: Staging/production isolation with separate backup trees

This system gives you the flexibility to run tournament events, test new configurations, and manage multiple server types while maintaining clean organization and safety.