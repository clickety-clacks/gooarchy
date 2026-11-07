use common::Failure;
use std::io::{BufRead, Write};

pub fn usage(message: impl Into<String>) -> Failure {
    Failure::with_code(2, message)
}

pub fn prompt(
    input: &mut impl BufRead,
    output: &mut impl Write,
    question: &str,
) -> Result<String, Failure> {
    write!(output, "{question}")?;
    output.flush()?;
    let mut answer = String::new();
    input.read_line(&mut answer)?;
    Ok(answer.trim().to_owned())
}

pub fn pick(
    input: &mut impl BufRead,
    output: &mut impl Write,
    choices: &[(String, String)],
    multi: bool,
    question: &str,
) -> Result<Vec<String>, Failure> {
    for (index, (_, label)) in choices.iter().enumerate() {
        writeln!(output, "{}. {label}", index + 1)?;
    }
    let answer = prompt(input, output, question)?;
    if answer.is_empty() || answer == "0" {
        return Ok(Vec::new());
    }

    let mut selected = Vec::new();
    for part in answer.split(|character: char| character.is_whitespace() || character == ',') {
        if part.is_empty() {
            continue;
        }
        let number = part
            .parse::<usize>()
            .map_err(|_| usage("choose listed numbers, or press Enter to cancel"))?;
        let choice = choices
            .get(
                number
                    .checked_sub(1)
                    .ok_or_else(|| usage("choice numbers start at 1"))?,
            )
            .ok_or_else(|| usage("choice number is not in the list"))?;
        if !selected.iter().any(|item| item == &choice.0) {
            selected.push(choice.0.clone());
        }
    }
    if selected.is_empty() {
        return Ok(Vec::new());
    }
    if !multi && selected.len() != 1 {
        return Err(usage("choose one number"));
    }
    Ok(selected)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn picker_supports_multiple_choices_and_cancellation() {
        let choices = vec![
            ("a".to_owned(), "Alpha".to_owned()),
            ("b".to_owned(), "Beta".to_owned()),
            ("c".to_owned(), "Gamma".to_owned()),
        ];
        let mut input = Cursor::new(b"1, 3 1\n".to_vec());
        let mut output = Vec::new();
        assert_eq!(
            pick(&mut input, &mut output, &choices, true, "Choose: ").unwrap(),
            ["a", "c"]
        );
        let mut input = Cursor::new(b"\n".to_vec());
        assert!(
            pick(&mut input, &mut output, &choices, false, "Choose: ")
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn picker_rejects_unknown_numbers_and_multiple_single_choices() {
        let choices = vec![("a".to_owned(), "Alpha".to_owned())];
        let mut output = Vec::new();
        assert!(
            pick(
                &mut Cursor::new(b"2\n".to_vec()),
                &mut output,
                &choices,
                false,
                "Choose: "
            )
            .is_err()
        );
        let choices = vec![
            ("a".to_owned(), "Alpha".to_owned()),
            ("b".to_owned(), "Beta".to_owned()),
        ];
        assert!(
            pick(
                &mut Cursor::new(b"1 2\n".to_vec()),
                &mut output,
                &choices,
                false,
                "Choose: "
            )
            .is_err()
        );
    }
}
