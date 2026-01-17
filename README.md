# Velociraptor Deployment

This project contains **AWS Cloudfront** templates to deploy Velociraptor [https://docs.velociraptor.app/](https://docs.velociraptor.app/). This project has two templates

- Operations
- Training

## Operations Template

This template is used to deploy Velociraptor for operational purposes. The default user is **vradmin** and the password is stored in AWS Secrets Manager. You can obtain this password using the following command:

```sh
# Replace HOSTNAME with the hostname inputted into the template
# You must have AWS CLI properly configured to execute this command
aws secretsmanager get-secret-value --secret-id VelociraptorAdminPassword-HOSTNAME --query SecretString --region us-east-1 --output text
```

## Training Template

This template is used for training purposes. It creates an Velociraptor instance on a public subnet and a Windows client in a private subnet. The Windows client will download the agent, install it, and connect to the server. Use the **UserList** parameter in the template to create students in the Velociraptor instance.

## 🚀 Quick Start

These templates require an account with AWS and knowledge of CloudFormation. Additionally, each template requires the user to enter various parameters to include:

- Keyname
- Hostname
- DomainName
- Azure OAuth (optional)
- UserList (optional)

1. Deploy template via CloudFormation web UI

or

1. Deploy template via AWS CLI using the following example

```sh
aws cloudformation deploy \
    --template-file aws-cf-velociraptor-training.yml \
    --stack-name velociraptor-training \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
    --parameter-overrides Key1=Value1 Key2=Value2
```

## ⚖️ Legal / License

This project is open source and distributed under the MIT License.

> This software is provided "as is", without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and noninfringement. In no event shall the authors be liable for any claim, damages, or other liability, whether in an action of contract, tort, or otherwise, arising from, out of, or in connection with the software or the use or other dealings in the software.

---

## 👨‍💻 Author

Created by Jacob Stauffer | CISSP, GCFA, GREM, OSCP — Contributions and PRs welcome!

<a href="https://www.buymeacoffee.com/jstauffer" target="_blank"><img src="https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png" alt="Buy Me A Coffee" style="height: 41px !important;width: 174px !important;box-shadow: 0px 3px 2px 0px rgba(190, 190, 190, 0.5) !important;-webkit-box-shadow: 0px 3px 2px 0px rgba(190, 190, 190, 0.5) !important;" ></a>
