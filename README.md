# 🚀 SQLiteo

> The native macOS SQLite browser built for normal people.

SQLiteo is a native macOS SQLite browser built with Swift and absolute precision. It's fast, it's light, and it doesn't try to reinvent the wheel &mdash; it just makes the wheel spin really, really well.

## ✨ Features

* 🚀 **Cmd+Enter Magic:** Execute your SQL queries faster than you can say "SELECT *". 
* 🕵️ **Fuzzy Finder:** Can't remember if the table was `user_profiles` or `profiles_user`? Just start typing at the bottom of the sidebar. It'll find it.
* 🔗 **FK Peeking:** Ever stare at a Foreign Key and wonder what's actually there? Modals show you the referenced data without losing your place.
* 📏 **Ad-hoc SQL Queries:** SQL queries are automatically stored on disk to save them for later use.
* 🌟 **Autocomplete Everything:** Autocomplete for table names, column names, and SQL keywords when writing queries.
* 💨 **Lazy (but Fast) Loading:** Data pagination is built-in. Whether you have 10 rows or 10,000, your Mac won't break a sweat.
* 💅 **Native & Snappy:** No Electron here. This is pure, unadulterated Swift.

<table>
  <tr>
    <td><a href="https://github.com/adamghill/sqliteo/blob/main/img/main.png?raw=true"><img src="https://github.com/adamghill/sqliteo/blob/main/img/main.png?raw=true" width="400" alt="Main Window"></a></td>
    <td><a href="https://github.com/adamghill/sqliteo/blob/main/img/table-data.png?raw=true"><img src="https://github.com/adamghill/sqliteo/blob/main/img/table-data.png?raw=true" width="400" alt="Table Data"></a></td>
  </tr>
  <tr>
    <td><a href="https://github.com/adamghill/sqliteo/blob/main/img/foreign-key-peek.png?raw=true"><img src="https://github.com/adamghill/sqliteo/blob/main/img/foreign-key-peek.png?raw=true" width="400" alt="Foreign Key Peek"></a></td>
    <td><a href="https://github.com/adamghill/sqliteo/blob/main/img/filters.png?raw=true"><img src="https://github.com/adamghill/sqliteo/blob/main/img/filters.png?raw=true" width="400" alt="Filters"></a></td>
  </tr>
  <tr>
    <td><a href="https://github.com/adamghill/sqliteo/blob/main/img/schema.png?raw=true"><img src="https://github.com/adamghill/sqliteo/blob/main/img/schema.png?raw=true" width="400" alt="Schema"></a></td>
    <td><a href="https://github.com/adamghill/sqliteo/blob/main/img/sql-editor.png?raw=true"><img src="https://github.com/adamghill/sqliteo/blob/main/img/sql-editor.png?raw=true" width="400" alt="SQL Editor"></a></td>
  </tr>
</table>

## 🛠️ Getting Started

1. Download the latest `.zip` from the [Releases](https://github.com/adamghill/sqliteo/releases) page.
2. Drag `SQLiteo.app` to your Applications folder.
3. Start queryin'.

> [!IMPORTANT]
> **"Apple could not verify..."?**
> Since SQLiteo isn't signed with an Apple Developer certificate (yet!), macOS will block it by default.
>
> **To open it:**
> 1. Try to open `SQLiteo.app` (it will fail with the warning).
> 2. Open **System Settings** -> **Privacy & Security**.
> 3. Scroll down to the **Security** section and click **Open Anyway**.
> 4. Authenticate and click **Open** one last time.
>
> *Alternatively, run this in Terminal:*
> ```bash
> xattr -cr /Applications/SQLiteo.app
> ```

## 🤝 Contributing

Have an idea for SQLiteo? Open a PR! We're all about that open-source love. 💖

## 📜 License

MIT
