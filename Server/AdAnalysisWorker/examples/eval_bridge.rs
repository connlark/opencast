//! Local, network-free adapter: evals use the exact serving prompt/validator.
use opencast_ad_analysis_worker::{
    promo_v3, prompt, types::AdAnalysisRequest, validation, windowing,
};
use serde_json::{json, Value};
use std::io::{self, Read};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    let command: Value = serde_json::from_str(&input)?;
    let request: AdAnalysisRequest = serde_json::from_value(command["request"].clone())?;
    let v3 = command["policy"] == promo_v3::POLICY;
    let result = match command["op"].as_str().ok_or("missing op")? {
        "repair" => promo_v3::repair_payload(
            command["payload"].clone(),
            &command["output"],
            &serde_json::from_value::<Vec<String>>(command["issues"].clone())?,
        )?,
        "check_repair" => {
            let before: promo_v3::Output = serde_json::from_value(command["before"].clone())?;
            let after: promo_v3::Output = serde_json::from_value(command["output"].clone())?;
            let old = promo_v3::validate_window(&request, before.clone());
            let mut checked = promo_v3::validate_window(&request, after.clone());
            if !promo_v3::preserves_verified_breaks(&old, &checked)
                || (checked.is_complete()
                    && !promo_v3::preserves_candidate_evidence(&request, &before, &after))
            {
                checked.issues.push("v3_repair_lost_candidate".into());
            }
            json!({"complete":checked.is_complete(),"spans":checked.spans,"warnings":checked.issues,"notices":checked.notices})
        }
        "prepare" => {
            json!({"windows":(if v3 {opencast_ad_analysis_worker::v3_windowing::analysis_windows(&request)} else {windowing::analysis_windows(&request)}).iter().map(|w|{
            let payload=if v3 {promo_v3::payload(w,command["thinking"].as_str())} else {prompt::gemini_request_payload(w,prompt::GeminiGenerationOptions::default())};
            json!({"request":w,"payload":payload})
        }).collect::<Vec<_>>()})
        }
        "validate" => {
            if v3 {
                let result =
                    match serde_json::from_value::<promo_v3::Output>(command["output"].clone()) {
                        Ok(output) if command["window"] == true => {
                            promo_v3::validate_window(&request, output)
                        }
                        Ok(output) => promo_v3::validate(&request, output),
                        Err(_) => promo_v3::Validation {
                            issues: vec!["v3_malformed_model_json".into()],
                            ..Default::default()
                        },
                    };
                json!({"complete":result.is_complete(),"spans":result.spans,"warnings":result.issues,"notices":result.notices})
            } else {
                let output: validation::ModelOutput =
                    serde_json::from_value(command["output"].clone())?;
                let (spans, warnings) = validation::validate_model_output(&request, output);
                json!({"complete":warnings.is_empty(),"spans":spans,"warnings":warnings})
            }
        }
        _ => return Err("unknown op".into()),
    };
    println!("{}", serde_json::to_string(&result)?);
    Ok(())
}
