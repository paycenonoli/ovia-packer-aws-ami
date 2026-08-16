pipeline {

    agent any

    environment {
        AWS_DEFAULT_REGION = 'us-east-1'
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Packer Init') {
            steps {
                sh '''
                    cd packer
                    packer init .
                '''
            }
        }

        stage('Packer Validate') {
            steps {
                sh '''
                    cd packer
                    packer fmt -check .
                    packer validate .
                '''
            }
        }

        stage('Packer Build') {
            steps {
                script {
                    def packerOutput = sh(
                        script: '''
                            cd packer
                            packer build .
                        ''',
                        returnStdout: true
                    ).trim()

                    echo packerOutput

                    def amiId = sh(
                        script: """
                            echo '${packerOutput}' |
                            grep 'us-east-1: ami-' |
                            tail -1 |
                            awk '{print \$2}'
                        """,
                        returnStdout: true
                    ).trim()

                    env.AMI_ID = amiId

                    echo "Packer created AMI: ${env.AMI_ID}"
                }
            }
        }

        stage('Terraform Init') {
            steps {
                sh '''
                    cd terraform
                    terraform init
                '''
            }
        }

        stage('Terraform Plan') {
            steps {
                sh '''
                    cd terraform
                    terraform plan -var="ami_id=${AMI_ID}"
                '''
            }
        }

        stage('Approve Deployment') {
            steps {
                input message: 'Deploy the new AMI to AWS?', ok: 'Deploy'
            }
        }

        stage('Terraform Apply') {
            steps {
                sh '''
                    cd terraform
                    terraform apply -auto-approve -var="ami_id=${AMI_ID}"
                '''
            }
        }
    }
}
