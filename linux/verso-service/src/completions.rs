//! Shell completions and the man page, both generated from the one clap definition.

use crate::cli_command;

/// Write completions for `shell` to stdout.
pub fn print_completions(shell: clap_complete::Shell) {
    let mut command = cli_command();
    let program = command.get_name().to_owned();
    clap_complete::generate(shell, &mut command, program, &mut std::io::stdout());
}

/// Write the man page (roff) to stdout.
pub fn print_man() -> anyhow::Result<()> {
    clap_mangen::Man::new(cli_command()).render(&mut std::io::stdout())?;
    Ok(())
}
