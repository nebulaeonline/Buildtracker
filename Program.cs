using System.Globalization;
using Microsoft.Data.Sqlite;

try
{
    string root = Directory.GetCurrentDirectory(), tag = "";
    bool init = false, reset = false, noinc = false, nolockout = false;
    long count = 0;
    var seen = new HashSet<string>(StringComparer.Ordinal);
    for (int i = 0; i < args.Length; i++)
    {
        string option = args[i];
        if (!seen.Add(option)) throw new ArgumentException($"Duplicate option: {option}");
        switch (option)
        {
            case "--help":
            case "-h":
                Console.WriteLine("""
                    Buildtracker - persistent SQLite build counters

                    Usage: bt [--root <DIR>] [--tag <TAG>] [--nolockout] [--init [COUNT] | --reset [COUNT] | --noinc]

                    No operation flag: increment the selected counter and print its value.
                    Lock waits time out after 5 seconds by default.
                    --init [COUNT]    Create or reset the counter (default: 0).
                    --reset [COUNT]   Reset an existing counter (default: 0).
                    --noinc           Print the current counter without incrementing.
                    --tag <TAG>       Select an independent, case-sensitive counter.
                    --root <DIR>      Store data in DIR/.buildtracker (default: current directory).
                    --nolockout       Wait indefinitely for database locks; locking stays enabled.
                    --help, -h        Show this help screen without changing counters.

                    Without --tag, select the main counter. COUNT must be an integer from
                    0 to 9223372036854775807. Operation flags cannot be combined.
                    Counters must be initialized before use or reset. Successful counter
                    operations print only the number. Errors go to stderr with exit code 1.

                    Examples:
                      bt --init                      Initialize the main counter to 0.
                      bt                             Increment and print the main counter.
                      bt --reset 100                 Reset the main counter to 100.
                      bt --tag api --init             Initialize the api counter to 0.
                      bt --tag api --reset 42         Reset the api counter to 42.
                      bt --tag api --reset            Reset the api counter to 0.
                      bt --root .. --tag api --noinc  Read api from the parent project.
                    """);
                return 0;
            case "--root": root = Value(args, ref i, option); break;
            case "--tag": tag = Value(args, ref i, option); break;
            case "--noinc": noinc = true; break;
            case "--nolockout": nolockout = true; break;
            case "--init":
            case "--reset":
                if (option == "--init") init = true;
                else reset = true;
                if (i + 1 < args.Length && !args[i + 1].StartsWith("--", StringComparison.Ordinal))
                {
                    if (!long.TryParse(args[++i], NumberStyles.None, CultureInfo.InvariantCulture, out count))
                        throw new ArgumentException("COUNT must be an integer between 0 and 9223372036854775807.");
                }
                break;
            default: throw new ArgumentException($"Unknown argument: {option}. Use --help for usage.");
        }
    }
    if ((init ? 1 : 0) + (reset ? 1 : 0) + (noinc ? 1 : 0) > 1)
        throw new ArgumentException("--init, --reset, and --noinc cannot be combined.");

    string directory = Path.Combine(Path.GetFullPath(root), ".buildtracker");
    string database = Path.Combine(directory, "builds.db");
    if (init) Directory.CreateDirectory(directory);
    else if (!File.Exists(database)) throw new InvalidOperationException("Counter is not initialized. Run bt --init with the same --root and --tag.");

    using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
    {
        DataSource = database,
        Mode = init ? SqliteOpenMode.ReadWriteCreate : SqliteOpenMode.ReadWrite,
        Pooling = false,
        DefaultTimeout = nolockout ? 0 : 5
    }.ToString());
    connection.Open();
    // Acquire the writer reservation before preparing statements, avoiding
    // competing prepared statements retaining read locks during a commit.
    using var transaction = noinc ? null : connection.BeginTransaction(deferred: false);
    using var command = connection.CreateCommand();
    command.Transaction = transaction;
    if (init)
    {
        command.CommandText = """
            CREATE TABLE IF NOT EXISTS counters (
                tag TEXT PRIMARY KEY NOT NULL,
                count INTEGER NOT NULL CHECK(typeof(count) = 'integer' AND count >= 0)
            ) WITHOUT ROWID;
            """;
        command.ExecuteNonQuery();
    }
    command.Parameters.AddWithValue("$tag", tag);
    if (init || reset)
    {
        command.Parameters.AddWithValue("$count", count);
        command.CommandText = reset
            ? "UPDATE counters SET count = $count WHERE tag = $tag RETURNING count;"
            : """
            INSERT INTO counters(tag, count) VALUES ($tag, $count)
            ON CONFLICT(tag) DO UPDATE SET count = excluded.count
            RETURNING count;
            """;
    }
    else command.CommandText = noinc
        ? "SELECT count FROM counters WHERE tag = $tag;"
        : "UPDATE counters SET count = count + 1 WHERE tag = $tag AND count < 9223372036854775807 RETURNING count;";

    object? result = command.ExecuteScalar();
    if (result is null)
        throw new InvalidOperationException("Counter is not initialized or has reached the maximum value. Run --init to initialize or reset it.");
    transaction?.Commit();
    Console.WriteLine(Convert.ToInt64(result, CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture));
    return 0;
}
catch (Exception exception) when (exception is ArgumentException or InvalidOperationException or IOException or UnauthorizedAccessException or SqliteException or NotSupportedException)
{
    Console.Error.WriteLine($"bt: {exception.Message}");
    return 1;
}

static string Value(string[] arguments, ref int index, string option)
{
    if (++index >= arguments.Length || string.IsNullOrWhiteSpace(arguments[index]) || arguments[index].StartsWith("--", StringComparison.Ordinal))
        throw new ArgumentException($"{option} requires a value.");
    return arguments[index];
}
