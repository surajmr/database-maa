# Lab 1: Deploy and Validate the Cloud-Native AI Workload in Primary Region OKE Cluster

## Introduction

Deploy the AI document application in the primary OKE cluster. Verify its components before configuring disaster recovery.

**Before you begin**

Complete the workshop introduction. Confirm your OCI credentials, compartment, and region information.

- **Primary region:** Ashburn (`us-ashburn-1`)
- **Standby region:** Phoenix (`us-phoenix-1`)

Run all commands from Cloud Shell in the Ashburn region. Do not use a local terminal or Cloud Shell in another region.

The application runs in the Kubernetes namespace `ai-fsdr-lab`. Use `-n ai-fsdr-lab` with `kubectl` commands throughout the workshop.

Estimated Time: 15 minutes

### Objectives

In this lab, you will:

- Deploy the application to the primary region.
- Confirm that the application components are running.
- Start cross-region replication for the Ollama application volume.
- Use the application to submit a question and upload a document.

## Task 1: Gather the Database OCID and Download the Script Package

1. Sign in to the OCI Console with the credentials provided with the lab environment. Make sure to select the **Ashburn** region (`us-ashburn-1`).
    
    ![Ashburn region console](./images/ashburn-region-console.png)

    After signing in, open the profile menu and select **Console settings**.

    ![Open OCI Console settings](./images/console-settings.png)

    Under **Display settings**, select **Dark mode**, then click **Update**. Use Dark mode for the remaining steps in this lab. If you prefer **Light mode**, you can continue to the next step without changing the setting.

    ![Select Dark mode in OCI Console settings](./images/display-settings-dark-mode.png)

2. In the OCI Console, open the navigation menu. Select **Oracle AI Database**, then **Autonomous AI Database**.

    **Compartment:** Select the compartment assigned to you.

    ![Oracle ADB menu](./images/adb-menu.png)

    Select the compartment (**LLXXXXXX-COMPARTMENT**) shown in the lab instructions. You can verify it with **View Login Info** at the top left of the instructions page. **LLXXXXXX** is the user name used to sign in to the OCI Console.

    Use the compartment selector's search field to enter your assigned compartment name, such as **LLXXXXXX-COMPARTMENT**, and then select the matching compartment from the results.
    
    **Expected result:** You should see an Autonomous Transaction Processing (ATP) database. In this workshop, **ATP** refers to the Autonomous AI Database used by the application. If you do not see one, verify the compartment. Its name should resemble **FsrAiAppDB-XXXXXX**.

    ![ATP Database](./images/atp-database.png)

    Open the three-dot menu (...) beside the ATP database. Select the option to copy the ATP OCID, then save it for use in **Task 2**.

    ![ATP Database OCID](./images/atp-database-ocid.png)


3. Before opening Cloud Shell, verify that the OCI Console is set to your assigned compartment, **LLXXXXXX-COMPARTMENT**. Selecting the correct compartment ensures that you can view and use the lab resources.

    Open **Cloud Shell** using the Developer tools (computer) icon next to **Ashburn**. Confirm that the Cloud Shell session region is `us-ashburn-1`, then keep this session open for the remaining commands.

    ![Navigate to Cloud Shell](./images/cloud-shell.png)

    Cloud Shell home directory opens after a few seconds and displays the prompt. If the tutorial appears, enter **N** to close it.

    ![Cloud Shell prompt](./images/cloud-shell-prompt.png)

    **Note:** Select the assigned compartment and open a lab resource, such as **Autonomous AI Database**, before opening Cloud Shell. If you open Cloud Shell directly without first selecting the compartment and resource, you may see a **Policy missing** error stating that you are not authorized to access Code Editor. Close the error, return to the OCI Console, select the correct compartment, and then open Cloud Shell from the resource page.

    ![Cloud Shell Policy missing error](./images/cloud-shell-policy-missing.png)

4. Download the application package from the Object Storage URL provided with the lab environment.

    **Ashburn Cloud Shell**

    ```bash
    <copy>
    wget -O oci-ai-resiliency-lab.zip 'https://idfwhcj05ugj.objectstorage.us-ashburn-1.oci.customer-oci.com/p/dIx74t1ht57X3smpT37SmYRdq8ohGV7bGjZxwjFgkCVd0QdOjsdI-wwNkVO_sgjX/n/idfwhcj05ugj/b/fsdrs/o/oci-ai-resiliency-lab.zip' && ls -ltr oci-ai-resiliency-lab.zip
    </copy>
    ```

    Press **Enter** to run the command. The file listing appears automatically after the download completes.
    ![Download application package](./images/download-application-package.png)

5. Extract the package and enter its directory.

    **Ashburn Cloud Shell**

    ```bash
    <copy>
    unzip oci-ai-resiliency-lab.zip && cd oci-ai-resiliency-lab
    </copy>
    ```
    ![Extract application package](./images/extract-application-package.png)

## Task 2: Deploy the Application and Configure Replication

1. Run the deployment script.

    In the Ashburn Cloud Shell, run:

    ```bash
    <copy>
    ./bootstrap-ai-fsdr-lab.sh
    </copy>
    ```

    When prompted, enter these values. Passwords remain hidden. Enter each password twice so the script can catch typing mistakes before deployment begins. Press **Enter** after each value.

    - **Database username: `ADMIN`**
    - **Database password: `AIWorld2026!`**
    - **Wallet password: `Admin123`**
    - **Ashburn ATP OCID: the OCID copied in Task 1, Step 2**

    **Note:** An incorrect database or wallet password will cause the deployment to fail.

    Verify each value, then press **Enter**.

    ![Deploy AI application](./images/deploy-ai-application.png)

2. Monitor the deployment. It takes approximately 5 minutes.

    If deployment fails, the script explains the likely cause and asks whether you want to retry. Choose whether to replace the ADB password, wallet password, or both. The existing Kubernetes resources are reused; cleanup is not required. The script allows up to three attempts. If you stop or use all attempts, verify the ADB username, ADB password, wallet password, selected ATP, and wallet, then rerun `./bootstrap-ai-fsdr-lab.sh`.

    ![Monitor AI application deployment](./images/monitor-ai-application-deployment-1.png)

    **Expected result:** The script returns to the shell prompt without an error. If it reports an error, verify the values from Step 1 and rerun the step.

    ![Monitor AI application deployment](./images/monitor-ai-application-deployment-2.png)

3. Start cross-region replication for the application data volume.

    In the Ashburn Cloud Shell, run:

    ```bash
    <copy>
    ./configure-crr-after-deploy.sh
    </copy>
    ```
    ![Start cross-region replication](./images/start-cross-region-replication.png)


4. Verify that the application resources are running in the `ai-fsdr-lab` namespace. Full Stack DR uses this namespace for the application resources.

    In the Ashburn Cloud Shell, run:

    ```bash
    <copy>
    kubectl -n ai-fsdr-lab get pods,svc,pvc
    </copy>
    ```
    ![Application details](./images/application-details.png)

    Click the **Application URL** displayed in the output of Step 4 or copy the `ai-frontend` service's **External IP** value and open it in a separate browser tab. This is the application URL. If no external IP appears, wait a few moments and run the command again. You will validate the application in the next task.


## Task 3: Validate the AI Application

1. Open the application URL in a separate browser tab. The URL may take a short time to become reachable after the External IP is assigned.

    In the chat window, enter the following question:

    **What is OCI Full Stack Disaster Recovery?**

    Confirm that the application returns a generic response based on the model, without retrieval-augmented generation (RAG) context. The response should not reference an uploaded document.

    **RAG note:** Retrieval-augmented generation (RAG) combines information retrieved from an uploaded document with the AI model's knowledge to generate a context-grounded response. RAG is not used for this first response because no document has been uploaded and indexed yet.

    ![Primary Ashburn AI workload showing healthy services and connected database](./images/validate-ai-application-primary.png)

    Confirm that the application shows **Active DB region** and **Connected DB region** as `us-ashburn-1`. Confirm that the API, Autonomous AI Database, and Ollama statuses show **ok** or **up**, and that the model is `granite4.1:3b`.

    ![Validate AI response without RAG](./images/validate-ai-response-without-rag.png)

2. Test the document retrieval experience.

    Download the [OCI Full Stack Disaster Recovery official documentation](https://c4u02.objectstorage.us-ashburn-1.oci.customer-oci.com/p/9DEArLjsgbKXuJgQtSG95E8hMXRFtxgHR8jiHbqz4HgyVYXVnSo0SC_s-zq5CJA3/n/c4u02/b/hosted-files/o/OCI%20Full%20Stack%20DR%20doc.pdf) to your local computer, not to Cloud Shell.

    Return to the AI application and upload the PDF. Select the file, click **Upload & Index**, and wait for the confirmation that the document was indexed into Autonomous AI Database. The application processes the document and stores its chunks and embeddings for RAG retrieval.

    ![Upload FSDR documentation](./images/upload-fsdr-doc.png)
    
3. In the chat window, enter the following question again:

    **What is OCI Full Stack Disaster Recovery?**

    Confirm that the application accepts the document and returns a context-grounded response using RAG from the uploaded documentation. The response should be based on both the document and the Granite model, and should reflect information from the document you uploaded.

    ![Validate AI response with RAG](./images/validate-ai-response-with-rag.png)

    **Follow-up questions:** You can ask additional questions about OCI Full Stack Disaster Recovery and verify that the responses continue to use relevant information from the uploaded documentation.

    For example, ask:

    **What are the supported members in OCI Full Stack DR?**

    ![Follow-up question about supported OCI Full Stack DR members](./images/follow-up-supported-members.png)

In Lab 2, you will configure OCI Full Stack Disaster Recovery for this AI workload, including the primary and standby DR protection groups and their recovery plans.

You may now [proceed to the next lab](#next).

## Acknowledgements

* **Author** - Suraj Ramesh, Lead Principal Product Manager, Oracle Database High Availability (HA), Scalability and Maximum Availability Architecture (MAA)
* **Last Updated By/Date** - September 2026
