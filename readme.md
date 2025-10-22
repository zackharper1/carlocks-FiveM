# 🚗 Standalone Vehicle Lock System

**Author:** H. Zack  
**Version:** 1.1.0  
**Framework:** Standalone (no ESX/QBCore)  
**Database:** MySQL (via `oxmysql`)  

A clean and efficient **FiveM vehicle lock system** featuring:
- 🔑 Vehicle saving tied to player’s Discord, Steam, or Rockstar license ID  
- 🔒 Lock/unlock with double-tap **E**  
- 💾 Saves keys persistently in a MySQL table  
- 🧰 Lockpick and hotwire support (chance-based)  
- ⚡ Lightweight and fully standalone — no dependencies except `oxmysql`  

---

## 📦 Installation

1. **Dependencies**
   - Install [`oxmysql`](https://github.com/overextended/oxmysql).
   - Ensure your server has MySQL access.

2. **Folder structure**
resources/
└── carlock/
├── fxmanifest.lua
├── client/
│ └── client.lua
├── server/
│ └── server.lua
└── sql/
└── carlock.sql


3. **Database setup**
- Import the SQL file into your database:
  ```sql
  CREATE TABLE IF NOT EXISTS carlock_vehicles (
      id INT AUTO_INCREMENT PRIMARY KEY,
      plate VARCHAR(32) UNIQUE,
      owner_identifier VARCHAR(64),
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  );
  ```

4. **Add to your `server.cfg`:**
```cfg
ensure oxmysql
ensure carlock